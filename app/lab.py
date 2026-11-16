"""The lab: a small table you can edit, to watch the server make history.

The time machine's own table, `article`, is read-only here: it holds Wikipedia's past.
`lab_page` (created by sql/04_lab.sql) is a second system-versioned table with a few
short articles and the server's own clock. Everything the lab does is one ordinary
statement, and none of them mentions history:

    save      UPDATE lab_page SET content = ..., editor = ..., summary = ... WHERE page_id = ...
    restore   UPDATE lab_page AS now JOIN lab_page FOR SYSTEM_TIME AS OF ... AS old ... SET ...
    delete    DELETE FROM lab_page WHERE page_id = ...
    undelete  INSERT INTO lab_page ... SELECT ... FROM lab_page FOR SYSTEM_TIME ALL ...

The history that the page then shows was written by MariaDB, not by this file.

The forms change data, so each carries a random token that is also kept in the reader's
session cookie; a request without the matching token is refused. That stops another web
site from submitting the forms on a reader's behalf.
"""

import hmac
import secrets

import pymysql
from flask import Blueprint, abort, flash, redirect, render_template, request, session, url_for

import moments
from db import Db

lab = Blueprint("lab", __name__, url_prefix="/lab")

TEXT_LIMIT = 200_000     # characters of article text
NAME_LIMIT = 60
SUMMARY_LIMIT = 200


def form_token():
    """The token for this reader's forms, made on first use."""
    if "form_token" not in session:
        session["form_token"] = secrets.token_urlsafe(32)
    return session["form_token"]


def require_form_token():
    """Refuse the request unless it carries the token this reader's forms were given.

    A reader who has never opened a lab page has no token at all, and then nothing
    matches: an empty token must not count as equal to a missing one.
    """
    sent = request.form.get("form_token", "")
    expected = session.get("form_token")
    if not expected or not hmac.compare_digest(sent, expected):
        abort(400, "This form has expired. Go back, reload the page and try again.")


def who_and_why(default_summary):
    """The editor name and edit summary from a form, trimmed to their limits."""
    editor = (request.form.get("editor") or "").strip()[:NAME_LIMIT] or "a visitor"
    summary = (request.form.get("summary") or "").strip()[:SUMMARY_LIMIT] or default_summary
    return editor, summary


def tell(db, what_happened):
    """After a change: say what happened and show the statement that did it."""
    flash({"what": what_happened, "sql": db.log[-1]["sql"], "ms": db.log[-1]["ms"]})


@lab.route("/")
def pages():
    with Db() as db:
        current = db.query("""
            SELECT page_id, title, CHAR_LENGTH(content) AS characters, editor,
                   ROW_START AS saved_at
            FROM lab_page
            ORDER BY title
        """)
        # Deleted pages are gone from the table but not from its history.
        deleted = db.query("""
            SELECT page_id, MIN(title) AS title, MAX(ROW_END) AS deleted_at
            FROM lab_page FOR SYSTEM_TIME ALL
            WHERE page_id NOT IN (SELECT page_id FROM lab_page)
            GROUP BY page_id
            ORDER BY title
        """)
        versions = db.one("SELECT COUNT(*) AS n FROM lab_page FOR SYSTEM_TIME ALL")["n"]
        return render_template("lab_pages.html", current=current, deleted=deleted,
                               versions=versions, form_token=form_token(),
                               sql_log=db.log, sql_ms=db.total_ms)


@lab.route("/<int:page_id>")
def page(page_id):
    at = moments.parse_moment(request.args.get("at"))
    with Db() as db:
        # lab_page was created with the short syntax, so its period columns are hidden.
        # They can still be read under the names ROW_START and ROW_END.
        versions = db.query("""
            SELECT title, editor, summary, CHAR_LENGTH(content) AS characters,
                   ROW_START AS row_start, ROW_END AS row_end,
                   ROW_END > CURRENT_TIMESTAMP(6) AS is_current
            FROM lab_page FOR SYSTEM_TIME ALL
            WHERE page_id = %s
            ORDER BY ROW_START DESC, ROW_END DESC
        """, (page_id,))
        if not versions:
            abort(404)
        if at:
            shown = db.one("""
                SELECT title, content, editor, summary, ROW_START AS row_start
                FROM lab_page FOR SYSTEM_TIME AS OF TIMESTAMP %s
                WHERE page_id = %s
            """, (moments.for_sql(at), page_id))
        else:
            shown = db.one("""
                SELECT title, content, editor, summary, ROW_START AS row_start
                FROM lab_page
                WHERE page_id = %s
            """, (page_id,))
        return render_template("lab_page.html", page_id=page_id, title=versions[0]["title"],
                               versions=versions, shown=shown,
                               exists_now=bool(versions[0]["is_current"]),
                               form_token=form_token(), text_limit=TEXT_LIMIT,
                               sql_log=db.log, sql_ms=db.total_ms)


@lab.route("/<int:page_id>/save", methods=["POST"])
def save(page_id):
    require_form_token()
    content = (request.form.get("content") or "").replace("\r\n", "\n")[:TEXT_LIMIT]
    editor, summary = who_and_why("edited in the lab")
    with Db() as db:
        # This is all an edit is. The server keeps the version it replaces.
        changed = db.execute("""
            UPDATE lab_page
            SET content = %s, editor = %s, summary = %s
            WHERE page_id = %s
        """, (content, editor, summary, page_id))
        if not changed:
            abort(404)
        tell(db, "Saved. The text you replaced is now a history row.")
    return redirect(url_for("lab.page", page_id=page_id))


@lab.route("/<int:page_id>/restore", methods=["POST"])
def restore(page_id):
    require_form_token()
    moment = moments.parse_moment(request.form.get("moment"))
    if moment is None:
        abort(400, "No moment to restore was given.")
    editor, _ = who_and_why("")
    summary = f"restored the text of {moments.in_words(moment, seconds=True)}"
    with Db() as db:
        # The table joined to its own past: `old` is the row as it stood at the moment,
        # `now` is the current row. Restoring is an ordinary edit, so it is versioned too.
        changed = db.execute("""
            UPDATE lab_page AS now
            JOIN lab_page FOR SYSTEM_TIME AS OF TIMESTAMP %s AS old USING (page_id)
            SET now.content = old.content, now.editor = %s, now.summary = %s
            WHERE now.page_id = %s
        """, (moments.for_sql(moment), editor, summary, page_id))
        if not changed:
            abort(404)
        tell(db, "Restored. The page has its old text again, as a new version.")
    return redirect(url_for("lab.page", page_id=page_id))


@lab.route("/<int:page_id>/delete", methods=["POST"])
def delete(page_id):
    require_form_token()
    with Db() as db:
        if not db.execute("DELETE FROM lab_page WHERE page_id = %s", (page_id,)):
            abort(404)
        tell(db, "Deleted. The row is gone from the table, and its history is still here.")
    return redirect(url_for("lab.page", page_id=page_id))


@lab.route("/<int:page_id>/undelete", methods=["POST"])
def undelete(page_id):
    require_form_token()
    editor, _ = who_and_why("")
    with Db() as db:
        # The newest version in the history is the page as it was when it was deleted.
        # The primary key refuses a second copy if the page already exists.
        try:
            db.execute("""
                INSERT INTO lab_page (page_id, title, content, editor, summary)
                SELECT page_id, title, content, %s, 'undeleted'
                FROM lab_page FOR SYSTEM_TIME ALL
                WHERE page_id = %s
                ORDER BY ROW_END DESC
                LIMIT 1
            """, (editor, page_id))
        except pymysql.err.IntegrityError:
            abort(400, "This page exists; there is nothing to undelete.")
        tell(db, "Undeleted. The newest version in the history is the current row again.")
    return redirect(url_for("lab.page", page_id=page_id))
