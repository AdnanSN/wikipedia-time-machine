"""Wikipedia Time Machine – web app (Milestone M2).

Routes
------
/                          Article list: title, version count, oldest save
/article/<page_id>         Article as it stood at ?at=YYYY-MM-DDTHH:MM (UTC)
/article/<page_id>/history All versions of one article, oldest first

Every query reads `article` with FOR SYSTEM_TIME — never the `revision` table.
Connection settings come from .env (same keys as scripts/run_sql.py).
Every connection sets time_zone = '+00:00' so all datetimes are UTC.
"""

import os
from datetime import datetime, timezone
from pathlib import Path

import pymysql
import pymysql.cursors
from flask import Flask, abort, redirect, render_template, request, url_for

app = Flask(__name__)

# ---------------------------------------------------------------------------
# Database connection
# ---------------------------------------------------------------------------

# Read the .env file from the repository root (one level above app/).
# Environment variables take precedence over .env values, exactly as
# scripts/run_sql.py does, so CI and Docker can override without editing files.
_ROOT = Path(__file__).resolve().parent.parent
_DEFAULTS = {
    "WTM_DB_HOST": "127.0.0.1",
    "WTM_DB_PORT": "3306",
    "WTM_DB_USER": "root",
    "WTM_DB_PASSWORD": "",
    "WTM_DB_NAME": "wiki_time_machine",
}


def _load_config():
    """Return db config dict from .env + environment (env vars win)."""
    cfg = dict(_DEFAULTS)
    env_file = _ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                if key in cfg:
                    cfg[key] = value
    for key in _DEFAULTS:
        if key in os.environ:
            cfg[key] = os.environ[key]
    return cfg


def get_db():
    """Open and return a PyMySQL connection with UTC timezone set."""
    cfg = _load_config()
    conn = pymysql.connect(
        host=cfg["WTM_DB_HOST"],
        port=int(cfg["WTM_DB_PORT"]),
        user=cfg["WTM_DB_USER"],
        password=cfg["WTM_DB_PASSWORD"],
        database=cfg["WTM_DB_NAME"],
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
        # Ensures every datetime we read back is UTC, matching the data.
        init_command="SET time_zone = '+00:00'",
    )
    return conn


# ---------------------------------------------------------------------------
# Route: / — article list
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    """List all articles with their version count and earliest save date.

    The query uses FOR SYSTEM_TIME ALL so it sees every historical row, not
    just the current one.  COUNT(*) gives the number of Wikipedia edits we
    imported; MIN(row_start) is when the oldest revision we have was saved.
    """
    sql = """
        -- Count every version (current + historical) for each article.
        SELECT page_id,
               title,
               COUNT(*)       AS versions,
               MIN(row_start) AS first_saved
        FROM article FOR SYSTEM_TIME ALL
        GROUP BY page_id, title
        ORDER BY title
    """
    with get_db() as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            articles = cur.fetchall()
    return render_template("index.html", articles=articles)


# ---------------------------------------------------------------------------
# Route: /article/<page_id> — article at a moment
# ---------------------------------------------------------------------------

def _parse_at(at_str):
    """Parse ?at=YYYY-MM-DDTHH:MM into a datetime, or return now (UTC)."""
    if at_str:
        try:
            # datetime-local inputs give us 'YYYY-MM-DDTHH:MM'
            return datetime.strptime(at_str, "%Y-%m-%dT%H:%M").replace(
                tzinfo=timezone.utc
            )
        except ValueError:
            pass
    return datetime.now(timezone.utc)


@app.route("/article/<int:page_id>")
def article(page_id):
    """Show the article as it stood at the moment given by ?at=.

    The MariaDB clause FOR SYSTEM_TIME AS OF looks at which row was current
    at that instant: row_start <= t < row_end.  We format the datetime as a
    TIMESTAMP literal because MariaDB requires a time component (not just a date).
    """
    at_dt = _parse_at(request.args.get("at"))
    # Format as MariaDB TIMESTAMP literal — must include seconds (AGENTS.md).
    at_ts = at_dt.strftime("%Y-%m-%d %H:%M:%S")

    sql = """
        -- Read the one row that was current at the given moment.
        SELECT title, rev_id, row_start, row_end, editor, summary,
               minor_edit, len, content
        FROM article FOR SYSTEM_TIME AS OF TIMESTAMP %(at_ts)s
        WHERE page_id = %(page_id)s
    """
    with get_db() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, {"at_ts": at_ts, "page_id": page_id})
            row = cur.fetchone()

    if row is None:
        # No revision existed yet at that moment, or the page_id is wrong.
        abort(404)

    # Find the neighbouring edits so the Prev/Next buttons work.
    # We ask for ALL versions ordered by save time, then find where this one
    # sits in that list.
    prev_at = next_at = None
    timeline_sql = """
        -- All versions for this article, sorted oldest first.
        SELECT row_start
        FROM article FOR SYSTEM_TIME ALL
        WHERE page_id = %(page_id)s
        ORDER BY row_start
    """
    with get_db() as conn:
        with conn.cursor() as cur:
            cur.execute(timeline_sql, {"page_id": page_id})
            timeline = [r["row_start"] for r in cur.fetchall()]

    # row_start is the save time of the version we're looking at.
    current_start = row["row_start"]
    if current_start in timeline:
        idx = timeline.index(current_start)
        if idx > 0:
            prev_at = timeline[idx - 1].strftime("%Y-%m-%dT%H:%M")
        if idx < len(timeline) - 1:
            next_at = timeline[idx + 1].strftime("%Y-%m-%dT%H:%M")

    from renderer import render_wikitext  # local import keeps app.py clean
    rendered_html = render_wikitext(row["content"] or "")

    return render_template(
        "article.html",
        row=row,
        page_id=page_id,
        at_dt=at_dt,
        at_str=at_dt.strftime("%Y-%m-%dT%H:%M"),
        rendered_html=rendered_html,
        prev_at=prev_at,
        next_at=next_at,
    )


# ---------------------------------------------------------------------------
# Route: /article/<page_id>/history — revision timeline
# ---------------------------------------------------------------------------

@app.route("/article/<int:page_id>/history")
def history(page_id):
    """List every version of an article, oldest first.

    FOR SYSTEM_TIME ALL returns both current and historical rows.
    Each row shows the revision id, who saved it, the edit summary,
    and a link to view the article at that exact moment.
    """
    # First get the article title so we can show it in the page heading.
    title_sql = """
        SELECT title FROM article WHERE page_id = %(page_id)s
    """
    timeline_sql = """
        -- Every version, sorted oldest first.
        SELECT rev_id, row_start, row_end, editor, summary, len, minor_edit
        FROM article FOR SYSTEM_TIME ALL
        WHERE page_id = %(page_id)s
        ORDER BY row_start
    """
    with get_db() as conn:
        with conn.cursor() as cur:
            cur.execute(title_sql, {"page_id": page_id})
            title_row = cur.fetchone()
            if title_row is None:
                abort(404)
            cur.execute(timeline_sql, {"page_id": page_id})
            versions = cur.fetchall()

    return render_template(
        "history.html",
        page_id=page_id,
        title=title_row["title"],
        versions=versions,
    )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    # Debug mode on for development; turn off (or use a WSGI server) in prod.
    app.run(debug=True, host="127.0.0.1", port=5000)
