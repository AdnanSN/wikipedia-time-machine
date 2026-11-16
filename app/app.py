"""Wikipedia time machine: the web page (milestones M2 and M6).

Pick an article and a moment, and read the article as it stood then.

Pages
-----
/                              every article as it stood at ?at=... (default: now)
/article/<page_id>             one article at that moment, with the picture of its life
/article/<page_id>/history     all its versions, newest first
/article/<page_id>/diff        what changed between ?from=... and ?to=...
/article/<page_id>/phrase      when the article said ?q=..., and who added and removed it
/search                        which articles said ?q=... at that moment, and since when
/about                         the table behind it all, as the server describes it
/lab ...                       a table you can edit, to watch history being made (lab.py)

Every page reads the system-versioned table `article` and nothing else: no page reads the
`revision` table, and there is no code anywhere that keeps a history. The SQL each page
ran is printed at its foot, with timings.

All times are UTC. Run with `python app/app.py`; settings come from `.env` (see db.py).
"""

import os
import secrets
from bisect import bisect_right

import pymysql
from flask import Flask, abort, render_template, request, url_for

import moments
from db import Db
from differ import diff_versions
from lab import lab
from renderer import render_with_notes, title_key
from timeline import strata, year_bars

app = Flask(__name__)
# Signs the cookie that protects the lab's forms. A fresh random key at every start is
# fine for a local demo; set WTM_APP_SECRET to keep sessions across restarts.
app.secret_key = os.environ.get("WTM_APP_SECRET") or secrets.token_hex(32)
app.config.update(SESSION_COOKIE_SAMESITE="Lax", SESSION_COOKIE_HTTPONLY=True,
                  MAX_CONTENT_LENGTH=1_000_000)
app.register_blueprint(lab)

VERSIONS_PER_PAGE = 100

app.jinja_env.filters["in_words"] = moments.in_words
app.jinja_env.filters["day"] = moments.day_in_words
app.jinja_env.filters["for_url"] = moments.for_url
app.jinja_env.filters["for_statement"] = moments.for_statement
app.jinja_env.globals["span_in_words"] = moments.span_in_words


@app.context_processor
def the_moment():
    """Every template knows where in time the reader is, to keep links in that moment."""
    at = moments.parse_moment(request.args.get("at"))
    return {"at": at, "at_url": moments.for_url(at) if at else None,
            "at_input": moments.for_input(at) if at else ""}


def show(template, db, **values):
    """Render a page together with the SQL that produced it."""
    return render_template(template, sql_log=db.log, sql_ms=db.total_ms, **values)


def like_pattern(phrase):
    """A LIKE pattern that finds the phrase anywhere, with %, _ and \\ meaning themselves."""
    escaped = phrase.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


# ---------------------------------------------------------------------------
# /  : the whole data set at one moment
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    at = moments.parse_moment(request.args.get("at"))
    with Db() as db:
        if at:
            # One statement moves the whole connection into the past ...
            db.travel_to(moments.for_sql(at))
        # ... so this query is the same for today and for any other day. It names no
        # time at all: under system_versioning_asof it returns the rows of that moment.
        articles = db.query("""
            SELECT page_id, title, rev_id, editor, len, row_start AS saved_at
            FROM article
            ORDER BY title
        """)
        # A query that states its own FOR SYSTEM_TIME keeps it, even while travelling.
        lifetimes = db.query("""
            SELECT page_id, title, MIN(row_start) AS first_saved, COUNT(*) AS versions,
                   SUM(row_start <= %s) AS versions_so_far
            FROM article FOR SYSTEM_TIME ALL
            GROUP BY page_id, title
            ORDER BY first_saved
        """, (moments.for_sql(at or moments.LATEST),))
        years = db.query("""
            SELECT YEAR(row_start) AS year, COUNT(*) AS edits
            FROM article FOR SYSTEM_TIME ALL
            GROUP BY YEAR(row_start)
            ORDER BY year
        """)

        existing = {row["page_id"] for row in articles}
        so_far = {row["page_id"]: row["versions_so_far"] for row in lifetimes}
        for row in articles:
            row["versions_so_far"] = so_far.get(row["page_id"])
        return show("index.html", db,
                    articles=articles,
                    not_yet=[row for row in lifetimes if row["page_id"] not in existing],
                    bars=year_bars(years),
                    total_bytes=sum(row["len"] or 0 for row in articles),
                    articles_ever=len(lifetimes),
                    versions_ever=sum(row["versions"] for row in lifetimes),
                    first_year=years[0]["year"] if years else None,
                    year_now=at.year if at else None)


# ---------------------------------------------------------------------------
# /article/<page_id>  : one article at one moment
# ---------------------------------------------------------------------------

@app.route("/article/<int:page_id>")
def article(page_id):
    at = moments.parse_moment(request.args.get("at"))
    with Db() as db:
        if at:
            # The time machine: the row that was current at that moment.
            #
            # ORDER BY row_end LIMIT 1 does not change the answer; an article has one
            # version at any moment. It changes the work. The primary key is
            # (page_id, row_end), so the server starts at the first version that ended
            # after the moment, and without the LIMIT it reads on through every later
            # version, because it cannot know they do not overlap. For the MariaDB
            # article in 2010 that is 990 rows read instead of 1 (measured in
            # experiments/growth/run.sql, part 6).
            version = db.one("""
                SELECT page_id, title, rev_id, editor, summary, minor_edit, len, tags, content,
                       row_start, row_end, row_end > CURRENT_TIMESTAMP(6) AS is_current
                FROM article FOR SYSTEM_TIME AS OF TIMESTAMP %s
                WHERE page_id = %s
                ORDER BY row_end
                LIMIT 1
            """, (moments.for_sql(at), page_id))
        else:
            # Without FOR SYSTEM_TIME a system-versioned table shows its current rows.
            version = db.one("""
                SELECT page_id, title, rev_id, editor, summary, minor_edit, len, tags, content,
                       row_start, row_end, row_end > CURRENT_TIMESTAMP(6) AS is_current
                FROM article
                WHERE page_id = %s
            """, (page_id,))

        if version is None:
            return not_yet_written(db, page_id, at)

        # The picture of its life: when each version started and how big it was.
        points = db.query("""
            SELECT row_start, len
            FROM article FOR SYSTEM_TIME ALL
            WHERE page_id = %s
            ORDER BY row_start
        """, (page_id,))
        # The version before this one: the row current one microsecond before this
        # one started. The version after it starts exactly at this one's row_end.
        previous = db.one("""
            SELECT row_start
            FROM article FOR SYSTEM_TIME AS OF TIMESTAMP %s
            WHERE page_id = %s
            ORDER BY row_end
            LIMIT 1
        """, (moments.for_sql(version["row_start"] - moments.ONE_MICROSECOND), page_id))
        others = db.query("SELECT page_id, title FROM article")
        newest = db.one("SELECT MAX(row_start) AS newest FROM article")["newest"]

        # Links between our articles stay in the same moment.
        pages = {title_key(row["title"]): row["page_id"] for row in others}

        def link_for(title):
            if title in pages:
                return url_for("article", page_id=pages[title], at=moments.for_url(at) if at else None)
            return None

        body, skipped = render_with_notes(version["content"] or "", link_for)
        starts = [point["row_start"] for point in points]
        return show("article.html", db,
                    version=version, page_id=page_id,
                    body=body, skipped=skipped,
                    source=request.args.get("view") == "source",
                    position=bisect_right(starts, version["row_start"]), versions=len(points),
                    picture=strata([(p["row_start"], p["len"]) for p in points],
                                   starts[0], newest, at),
                    previous_at=previous["row_start"] if previous else None,
                    next_at=None if version["is_current"] else version["row_end"],
                    reverted="mw-reverted" in (version["tags"] or "").split(","))


def not_yet_written(db, page_id, at):
    """The article exists, but not at that moment: say when it starts."""
    first = db.one("""
        SELECT MIN(title) AS title, MIN(row_start) AS first_saved, COUNT(*) AS versions
        FROM article FOR SYSTEM_TIME ALL
        WHERE page_id = %s
    """, (page_id,))
    if not first or not first["versions"]:
        abort(404)
    return show("missing.html", db, page_id=page_id, first=first, asked=at), 404


# ---------------------------------------------------------------------------
# /article/<page_id>/history  : every version
# ---------------------------------------------------------------------------

@app.route("/article/<int:page_id>/history")
def history(page_id):
    page_number = max(request.args.get("page", 1, type=int), 1)
    with Db() as db:
        counted = db.one("""
            SELECT MIN(title) AS title, COUNT(*) AS versions
            FROM article FOR SYSTEM_TIME ALL
            WHERE page_id = %s
        """, (page_id,))
        if not counted["versions"]:
            abort(404)
        # LAG() looks one version back, so each row can say how much the edit added or
        # removed. The window is computed before LIMIT cuts the page out. (len is
        # unsigned, and unsigned numbers cannot go below zero, hence the two CASTs.)
        versions = db.query("""
            SELECT rev_id, editor, summary, minor_edit, len, tags, row_start, row_end,
                   row_end > CURRENT_TIMESTAMP(6) AS is_current,
                   CAST(len AS SIGNED) - CAST(LAG(len) OVER (ORDER BY row_start) AS SIGNED)
                     AS bytes_changed
            FROM article FOR SYSTEM_TIME ALL
            WHERE page_id = %s
            ORDER BY row_start DESC
            LIMIT %s OFFSET %s
        """, (page_id, VERSIONS_PER_PAGE, (page_number - 1) * VERSIONS_PER_PAGE))
        for row in versions:
            row["reverted"] = "mw-reverted" in (row["tags"] or "").split(",")
        return show("history.html", db, page_id=page_id, title=counted["title"],
                    versions=versions, total=counted["versions"], page_number=page_number,
                    pages=(counted["versions"] + VERSIONS_PER_PAGE - 1) // VERSIONS_PER_PAGE)


# ---------------------------------------------------------------------------
# /article/<page_id>/diff  : two moments, side by side (M6)
# ---------------------------------------------------------------------------

@app.route("/article/<int:page_id>/diff")
def diff(page_id):
    older = moments.parse_moment(request.args.get("from"))
    newer = moments.parse_moment(request.args.get("to"))
    with Db() as db:
        if newer is None:
            current = db.one("SELECT row_start FROM article WHERE page_id = %s", (page_id,))
            if current is None:
                abort(404)
            newer = current["row_start"]
        if older is None:
            # No "from": compare with the version before the one current at "to".
            there = db.one("""
                SELECT row_start
                FROM article FOR SYSTEM_TIME AS OF TIMESTAMP %s
                WHERE page_id = %s
            """, (moments.for_sql(newer), page_id))
            if there is None:
                return not_yet_written(db, page_id, newer)
            older = there["row_start"] - moments.ONE_MICROSECOND
        if older > newer:
            older, newer = newer, older

        # One query, two moments: each reference to the table has its own AS OF.
        pair = db.one("""
            SELECT new.title,
                   old.rev_id AS old_rev, old.row_start AS old_saved, old.editor AS old_editor,
                   old.len AS old_len, old.content AS old_text,
                   new.rev_id AS new_rev, new.row_start AS new_saved, new.editor AS new_editor,
                   new.len AS new_len, new.content AS new_text
            FROM article FOR SYSTEM_TIME AS OF TIMESTAMP %s AS old
            JOIN article FOR SYSTEM_TIME AS OF TIMESTAMP %s AS new USING (page_id)
            WHERE page_id = %s
        """, (moments.for_sql(older), moments.for_sql(newer), page_id))
        if pair is None:
            return not_yet_written(db, page_id, older)

        # BETWEEN returns every version that was current at some point from the first
        # moment to the second, including the one already current at the first; the
        # WHERE leaves that one out, so what remains are the saves in between.
        between = db.one("""
            SELECT COUNT(*) AS saves, COUNT(DISTINCT editor) AS editors
            FROM article FOR SYSTEM_TIME BETWEEN TIMESTAMP %s AND TIMESTAMP %s
            WHERE page_id = %s AND row_start > %s
        """, (moments.for_sql(older), moments.for_sql(newer), page_id, moments.for_sql(older)))

        return show("diff.html", db, page_id=page_id, pair=pair, between=between,
                    older=older, newer=newer,
                    changes=diff_versions(pair["old_text"] or "", pair["new_text"] or ""))


# ---------------------------------------------------------------------------
# /article/<page_id>/phrase  : when did the article say this?
# ---------------------------------------------------------------------------

@app.route("/article/<int:page_id>/phrase")
def phrase(page_id):
    wanted = (request.args.get("q") or "").strip()[:200]
    with Db() as db:
        titled = db.one("SELECT title FROM article WHERE page_id = %s", (page_id,))
        if titled is None:
            abort(404)
        periods = []
        if len(wanted) >= 2:
            # For every version: does it contain the phrase, and did the version before?
            # The rows where the two answers differ are the edits that added the phrase
            # or took it out.
            turns = db.query("""
                SELECT row_start, rev_id, editor, summary, has_phrase
                FROM (SELECT row_start, rev_id, editor, summary,
                             content LIKE %s AS has_phrase,
                             LAG(content LIKE %s) OVER (ORDER BY row_start) AS had_phrase
                      FROM article FOR SYSTEM_TIME ALL
                      WHERE page_id = %s) AS version
                WHERE has_phrase <> COALESCE(had_phrase, 0)
                ORDER BY row_start
            """, (like_pattern(wanted), like_pattern(wanted), page_id))
            # Turns alternate: added, removed, added, ... Pair them into periods.
            for added, removed in zip(turns[0::2], turns[1::2] + [None]):
                periods.append({"added": added, "removed": removed})
        return show("phrase.html", db, page_id=page_id, title=titled["title"],
                    wanted=wanted, periods=periods)


# ---------------------------------------------------------------------------
# /search  : which articles said it, then and ever
# ---------------------------------------------------------------------------

@app.route("/search")
def search():
    wanted = (request.args.get("q") or "").strip()[:200]
    at = moments.parse_moment(request.args.get("at"))
    with Db() as db:
        saying_it, first_said = [], []
        if len(wanted) >= 2:
            if at:
                db.travel_to(moments.for_sql(at))
            # The articles that say it at the reader's moment (or now).
            saying_it = db.query("""
                SELECT page_id, title, len, row_start AS saved_at
                FROM article
                WHERE content LIKE %s
                ORDER BY title
            """, (like_pattern(wanted),))
            # And across all of history: when each article first said it.
            first_said = db.query("""
                SELECT page_id, title, MIN(row_start) AS first_said, COUNT(*) AS versions_saying_it
                FROM article FOR SYSTEM_TIME ALL
                WHERE content LIKE %s
                GROUP BY page_id, title
                ORDER BY first_said
            """, (like_pattern(wanted),))
        return show("search.html", db, wanted=wanted, saying_it=saying_it, first_said=first_said)


# ---------------------------------------------------------------------------
# /about  : the table definition that replaces the application code
# ---------------------------------------------------------------------------

@app.route("/about")
def about():
    with Db() as db:
        server = db.one("SELECT VERSION() AS version, @@time_zone AS time_zone")
        definition = db.one("SHOW CREATE TABLE article")["Create Table"]
        counts = db.one("""
            SELECT (SELECT COUNT(*) FROM article) AS current_rows,
                   (SELECT COUNT(*) FROM article FOR SYSTEM_TIME ALL) AS all_rows,
                   (SELECT MIN(row_start) FROM article FOR SYSTEM_TIME ALL) AS oldest,
                   (SELECT MAX(row_start) FROM article) AS newest
        """)
        return show("about.html", db, server=server, definition=definition, counts=counts)


# ---------------------------------------------------------------------------
# When something goes wrong
# ---------------------------------------------------------------------------

@app.errorhandler(404)
def not_found(error):
    return render_template("error.html", heading="No such page",
                           message="The time machine has no page at this address.",
                           steps=[]), 404


@app.errorhandler(400)
def bad_request(error):
    return render_template("error.html", heading="That request could not be used",
                           message=error.description, steps=[]), 400


# MariaDB's error numbers for "could not connect or log in" and for "that database or
# table does not exist". Anything else is a mistake in a statement and is shown as such.
CANNOT_CONNECT = {1044, 1045, 2002, 2003, 2005, 2006, 2013}
NOT_BUILT = {1049, 1146, 1054}


@app.errorhandler(pymysql.err.MySQLError)
def database_error(error):
    number = error.args[0] if error.args else None
    if number in CANNOT_CONNECT:
        return render_template(
            "error.html", heading="The database did not answer",
            message="The page could not connect to MariaDB with the settings in .env.",
            steps=["Start your MariaDB server.",
                   "Copy .env.example to .env and fill in WTM_DB_PASSWORD (and WTM_DB_PORT if it is not 3306).",
                   "Build the database: python scripts/setup.py"]), 503
    if number in NOT_BUILT:
        return render_template(
            "error.html", heading="The database is not built yet",
            message="MariaDB answered, but the wiki_time_machine tables are missing or older than this page expects.",
            steps=["Build the database: python scripts/setup.py"]), 503
    app.logger.error("MariaDB refused a statement: %s", error)
    return render_template(
        "error.html", heading="MariaDB refused a statement",
        message=f"The server answered with error {number}. The full message is in the application's log.",
        steps=[]), 500


if __name__ == "__main__":
    # Debug mode stays off unless you ask for it: it lets anyone who can reach the page
    # run code on this machine.
    app.run(host=os.environ.get("WTM_APP_HOST", "127.0.0.1"),
            port=int(os.environ.get("WTM_APP_PORT", "5000")),
            debug=os.environ.get("WTM_APP_DEBUG") == "1")
