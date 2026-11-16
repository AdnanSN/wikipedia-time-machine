"""Database access for the web app.

Two things live here:

* the connection settings, read from the same `.env` file and environment variables
  that `scripts/run_sql.py` uses, so the app and the build always talk to the same server;
* `Db`, one connection for one web request. It remembers every statement it runs, with
  its timing, so that each page can show the SQL it was made from. The point of this
  project is what the SQL can do; the page should not hide it.

Every statement is sent with its values as parameters (`%s`), never pasted into the SQL
text by hand, so a value typed by a reader cannot change the statement.
"""

import os
import textwrap
import time
from pathlib import Path

import pymysql
import pymysql.cursors

ROOT = Path(__file__).resolve().parent.parent

DEFAULTS = {
    "WTM_DB_HOST": "127.0.0.1",
    "WTM_DB_PORT": "3306",
    "WTM_DB_USER": "root",
    "WTM_DB_PASSWORD": "",
    "WTM_DB_NAME": "wiki_time_machine",
}

# Long values (an article's whole text) are shortened when a statement is shown.
SHOWN_VALUE_LIMIT = 80


def load_config():
    """Defaults, overridden by the .env file, overridden by environment variables."""
    config = dict(DEFAULTS)
    env_file = ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                key = key.strip()
                if key in config:
                    config[key] = value.strip().strip('"').strip("'")
    for key in DEFAULTS:
        if key in os.environ:
            config[key] = os.environ[key]
    return config


class Db:
    """One connection, opened for one request and closed at its end.

    Use it as `with Db() as db:`. `db.log` lists what ran: the statement as it was sent,
    how many rows came back, and how long it took.
    """

    def __init__(self):
        config = load_config()
        self.connection = pymysql.connect(
            host=config["WTM_DB_HOST"],
            port=int(config["WTM_DB_PORT"]),
            user=config["WTM_DB_USER"],
            password=config["WTM_DB_PASSWORD"],
            database=config["WTM_DB_NAME"],
            charset="utf8mb4",
            cursorclass=pymysql.cursors.DictCursor,
            autocommit=True,
            connect_timeout=5,
            # TIMESTAMP columns convert to and from the session time zone. Wikipedia's
            # times are UTC, so every connection reads and writes UTC.
            init_command="SET time_zone = '+00:00'",
        )
        self.log = []

    def __enter__(self):
        return self

    def __exit__(self, *error):
        self.connection.close()

    def _run(self, sql, params):
        sql = textwrap.dedent(sql).strip()
        with self.connection.cursor() as cursor:
            started = time.perf_counter()
            cursor.execute(sql, params)
            rows = cursor.fetchall()
            elapsed_ms = (time.perf_counter() - started) * 1000
            self.log.append({
                "sql": cursor.mogrify(sql, _shortened(params)),
                "rows": len(rows) if cursor.description else cursor.rowcount,
                "returns_rows": cursor.description is not None,
                "ms": elapsed_ms,
            })
            return rows, cursor.rowcount

    def query(self, sql, params=None):
        """Run a SELECT and return its rows as a list of dictionaries."""
        return list(self._run(sql, params)[0])

    def one(self, sql, params=None):
        """Run a SELECT and return its first row, or None."""
        rows = self._run(sql, params)[0]
        return rows[0] if rows else None

    def execute(self, sql, params=None):
        """Run a statement that changes something and return how many rows it touched."""
        return self._run(sql, params)[1]

    def travel_to(self, moment_sql):
        """Make every later query on this connection read the past.

        `system_versioning_asof` adds an implicit `FOR SYSTEM_TIME AS OF` to every
        system-versioned table a query reads, so the same SELECT that shows today's
        articles shows the articles of that moment. A query that states its own
        `FOR SYSTEM_TIME` clause keeps it.
        """
        self.execute("SET system_versioning_asof = %s", (moment_sql,))

    @property
    def total_ms(self):
        return sum(entry["ms"] for entry in self.log)


def _shortened(params):
    """The same parameters, with long strings cut, for showing a statement on the page."""
    def cut(value):
        if isinstance(value, str) and len(value) > SHOWN_VALUE_LIMIT:
            return value[:SHOWN_VALUE_LIMIT - 20] + f"... ({len(value):,} characters)"
        return value

    if isinstance(params, dict):
        return {key: cut(value) for key, value in params.items()}
    if isinstance(params, (list, tuple)):
        return tuple(cut(value) for value in params)
    return params
