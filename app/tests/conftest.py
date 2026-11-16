"""Shared set-up for the tests.

Two kinds of tests live in this folder:

* tests of the pure Python parts (renderer, differ, moments, timeline): no database;
* tests of the pages themselves (test_pages.py), which need the built database.

The page tests use the `client` fixture below. It gives every test one database
connection inside a transaction that is rolled back at the end, so even the tests that
edit, delete and restore pages in the lab leave the database exactly as they found it.

If MariaDB cannot be reached the page tests are skipped, with the reason. Set
WTM_REQUIRE_DB=1 (as CI does) to make that a failure instead, so a broken connection
cannot pass for a green run.
"""

import os
import sys
from pathlib import Path

import pytest

# The app's modules import each other by plain name (import moments), as they do when
# the app is started with `python app/app.py`.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


class BorrowedDb:
    """Stands in for `Db()` in the page code: hands out the test's one connection."""

    def __init__(self, shared):
        self.shared = shared

    def __call__(self):          # the page code calls Db()
        return self

    def __enter__(self):
        self.shared.log = []
        return self.shared

    def __exit__(self, *error):
        # A page may have moved the session into the past; the next page starts in the
        # present, as it would on a connection of its own.
        with self.shared.connection.cursor() as cursor:
            cursor.execute("SET system_versioning_asof = DEFAULT")


@pytest.fixture(scope="session")
def database_problem():
    """None if the built database answers; otherwise the reason, found out only once."""
    import pymysql

    from db import Db

    try:
        with Db() as db:
            if not db.one("SELECT COUNT(*) AS n FROM article")["n"]:
                return "the article table is empty: build the database first"
            db.one("SELECT COUNT(*) AS n FROM lab_page")
    except pymysql.err.MySQLError as error:
        return f"MariaDB is not reachable or the database is not built: {error}"
    return None


@pytest.fixture
def client(monkeypatch, database_problem):
    import app as app_module
    import lab as lab_module
    from db import Db

    if database_problem:
        if os.environ.get("WTM_REQUIRE_DB") == "1":
            pytest.fail(f"WTM_REQUIRE_DB=1, but {database_problem}")
        pytest.skip(database_problem)

    shared = Db()
    shared.connection.autocommit(False)
    shared.connection.begin()
    borrowed = BorrowedDb(shared)
    monkeypatch.setattr(app_module, "Db", borrowed)
    monkeypatch.setattr(lab_module, "Db", borrowed)
    app_module.app.config.update(TESTING=True)
    try:
        with app_module.app.test_client() as test_client:
            test_client.db = shared      # for tests that want to ask the database directly
            yield test_client
    finally:
        shared.connection.rollback()
        shared.connection.close()
