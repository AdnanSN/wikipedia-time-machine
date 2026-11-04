#!/usr/bin/env python3
"""Download the revision history of the articles listed in data/articles.txt.

    python scripts/fetch_revisions.py           fetch the articles that are missing
    python scripts/fetch_revisions.py --force   fetch every article again
    python scripts/fetch_revisions.py --check   verify the files against data/pages.tsv

For each article it writes data/revisions/<page_id>.jsonl.xz: one JSON object per
revision, oldest first, with the wikitext and the edit's metadata. It then rewrites
data/pages.tsv, one line per article with its revision count and date range.

Only revisions saved before CUTOFF are fetched, so a later run returns the same data.
Each revision's text is checked against the SHA-1 that Wikipedia reports for it.

Uses only the Python standard library (3.9 or newer) and the public MediaWiki API,
following https://www.mediawiki.org/wiki/API:Etiquette: one request at a time, a
descriptive User-Agent, and maxlag so the servers can ask us to slow down.
"""

import argparse
import gzip
import hashlib
import json
import lzma
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARTICLES = ROOT / "data" / "articles.txt"
PAGES = ROOT / "data" / "pages.tsv"
REVISIONS = ROOT / "data" / "revisions"

API = "https://en.wikipedia.org/w/api.php"
CUTOFF = "2026-11-01T00:00:00Z"
USER_AGENT = ("wikipedia-time-machine/1.0 "
              "(https://github.com/AdnanSN/wikipedia-time-machine; "
              "student project at Constructor University)")

# MediaWiki's rev_deleted bits, kept so that hidden text is not mistaken for empty text.
DELETED_TEXT, DELETED_COMMENT, DELETED_USER = 1, 2, 4


def api_get(params):
    """One GET request to the API, retried on network errors, 429/5xx and maxlag."""
    query = dict(params, format="json", formatversion="2", maxlag="5", errorformat="plaintext")
    url = API + "?" + urllib.parse.urlencode(query)
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT,
                                                   "Accept-Encoding": "gzip"})
    for attempt in range(1, 8):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                body = response.read()
                if response.headers.get("Content-Encoding") == "gzip":
                    body = gzip.decompress(body)
            data = json.loads(body)
        except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
            retry_after = 5 * attempt
            if isinstance(error, urllib.error.HTTPError):
                if error.code not in (429, 500, 502, 503, 504):
                    raise
                retry_after = int(error.headers.get("Retry-After") or retry_after)
            print(f"  network problem ({error}), retrying in {retry_after} s", file=sys.stderr)
            time.sleep(retry_after)
            continue
        errors = data.get("errors") or []
        if any(e.get("code") == "maxlag" for e in errors):
            time.sleep(5 * attempt)
            continue
        if errors:
            raise RuntimeError(f"API error: {errors}")
        return data
    raise RuntimeError(f"giving up after repeated failures: {url}")


def read_titles():
    titles = []
    for line in ARTICLES.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            titles.append(line)
    if len(set(titles)) != len(titles):
        sys.exit("data/articles.txt lists a title twice")
    return titles


def resolve(titles):
    """Map each listed title to (page_id, current title), following redirects."""
    resolved = {}
    for start in range(0, len(titles), 50):
        batch = titles[start:start + 50]
        data = api_get({"action": "query", "prop": "info", "redirects": "1",
                        "titles": "|".join(batch)})
        query = data["query"]
        renames = {}
        for step in query.get("normalized", []) + query.get("redirects", []):
            renames[step["from"]] = step["to"]
        pages = {page["title"]: page for page in query["pages"]}
        for title in batch:
            target = title
            while target in renames:
                target = renames[target]
            page = pages.get(target)
            if page is None or page.get("missing") or page.get("invalid"):
                sys.exit(f"Wikipedia has no article called {title!r}")
            resolved[title] = (page["pageid"], page["title"])
    page_ids = [page_id for page_id, _ in resolved.values()]
    if len(set(page_ids)) != len(page_ids):
        sys.exit("two titles in data/articles.txt lead to the same article")
    return resolved


def to_record(rev):
    """Flatten one API revision into the record we store."""
    slot = rev.get("slots", {}).get("main", {})
    deleted = 0
    if rev.get("texthidden") or slot.get("texthidden"):
        deleted |= DELETED_TEXT
    if rev.get("commenthidden"):
        deleted |= DELETED_COMMENT
    if rev.get("userhidden"):
        deleted |= DELETED_USER
    return {
        "rev_id": rev["revid"],
        "parent_id": rev.get("parentid") or None,
        "timestamp": rev["timestamp"],
        "minor": bool(rev.get("minor")),
        "user": rev.get("user"),
        "comment": rev.get("comment"),
        "size": rev.get("size"),
        "sha1": None if rev.get("sha1hidden") else rev.get("sha1"),
        "tags": rev.get("tags", []),
        "deleted": deleted,
        "content": None if deleted & DELETED_TEXT else slot.get("content"),
    }


def fetch_page(page_id):
    """Every revision of one page saved before CUTOFF, oldest first."""
    records, cont = [], {}
    while True:
        data = api_get({"action": "query", "prop": "revisions", "pageids": page_id,
                        "rvprop": "ids|timestamp|flags|user|comment|size|sha1|tags|content",
                        "rvslots": "main", "rvlimit": "max", "rvdir": "newer",
                        "rvend": CUTOFF, **cont})
        records.extend(to_record(rev) for rev in data["query"]["pages"][0].get("revisions", []))
        print(f"\r  {len(records)} revisions", end="", file=sys.stderr, flush=True)
        if "continue" not in data:
            break
        cont = data["continue"]
        time.sleep(0.1)
    print(file=sys.stderr)
    return records


def sha1_problems(records):
    """Revisions whose text does not hash to the SHA-1 Wikipedia gave for it."""
    bad = []
    for r in records:
        if r["content"] is not None and r["sha1"]:
            if hashlib.sha1(r["content"].encode("utf-8")).hexdigest() != r["sha1"]:
                bad.append(r["rev_id"])
    return bad


def write_records(path, records):
    tmp = path.with_suffix(".tmp")
    with lzma.open(tmp, "wt", encoding="utf-8", newline="\n") as out:
        for r in records:
            out.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


def read_records(path):
    with lzma.open(path, "rt", encoding="utf-8") as f:
        return [json.loads(line) for line in f]


def summary(page_id, title, records):
    return {"page_id": page_id, "title": title, "revisions": len(records),
            "first_timestamp": records[0]["timestamp"], "last_timestamp": records[-1]["timestamp"],
            "last_rev_id": records[-1]["rev_id"],
            "bytes": sum(len((r["content"] or "").encode("utf-8")) for r in records)}


COLUMNS = ["page_id", "title", "revisions", "first_timestamp", "last_timestamp",
           "last_rev_id", "bytes"]


def write_pages(rows):
    lines = ["\t".join(COLUMNS)] + ["\t".join(str(row[c]) for c in COLUMNS) for row in rows]
    PAGES.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def read_pages():
    lines = PAGES.read_text(encoding="utf-8").splitlines()
    header = lines[0].split("\t")
    return [dict(zip(header, line.split("\t"))) for line in lines[1:] if line]


def check():
    """Verify every file against data/pages.tsv and the SHA-1s inside it."""
    failures = 0
    for row in read_pages():
        path = REVISIONS / f"{row['page_id']}.jsonl.xz"
        if not path.exists():
            print(f"MISSING  {row['title']}: {path.name}")
            failures += 1
            continue
        records = read_records(path)
        actual = summary(int(row["page_id"]), row["title"], records)
        differs = [c for c in COLUMNS if str(actual[c]) != row[c]]
        bad = sha1_problems(records)
        ok = not differs and not bad
        failures += not ok
        print(f"{'ok' if ok else 'FAILED':8} {row['title']}: {len(records)} revisions"
              + (f", differs in {differs}" if differs else "")
              + (f", {len(bad)} SHA-1 mismatches" if bad else ""))
    print("all files match data/pages.tsv" if not failures else f"{failures} problem(s)")
    return failures == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--force", action="store_true", help="fetch every article again")
    parser.add_argument("--check", action="store_true", help="only verify the existing files")
    args = parser.parse_args()
    if args.check:
        sys.exit(0 if check() else 1)

    REVISIONS.mkdir(parents=True, exist_ok=True)
    titles = read_titles()
    print(f"Resolving {len(titles)} titles", file=sys.stderr)
    resolved = resolve(titles)
    rows = []
    for title in titles:
        page_id, current_title = resolved[title]
        path = REVISIONS / f"{page_id}.jsonl.xz"
        if path.exists() and not args.force:
            print(f"{current_title}: already downloaded", file=sys.stderr)
            records = read_records(path)
        else:
            print(f"{current_title} (page {page_id})", file=sys.stderr)
            records = fetch_page(page_id)
            if not records:
                sys.exit(f"no revisions before {CUTOFF} for {current_title!r}")
            bad = sha1_problems(records)
            if bad:
                sys.exit(f"SHA-1 mismatch in {current_title!r}, revisions {bad[:5]}")
            write_records(path, records)
        rows.append(summary(page_id, current_title, records))
    write_pages(rows)
    total = sum(row["revisions"] for row in rows)
    size = sum(row["bytes"] for row in rows) / 1e6
    print(f"Done: {len(rows)} articles, {total} revisions, {size:.1f} MB of wikitext",
          file=sys.stderr)


if __name__ == "__main__":
    main()
