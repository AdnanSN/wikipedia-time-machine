-- run_all.sql: build the database from the downloaded revisions and run every demo and check.
--
-- The short way, from the repository folder:
--     python scripts/setup.py
-- which runs the two steps below with the connection settings from .env. By hand:
--     python scripts/build_sql.py
--     mariadb -u root -p --table --abort-source-on-error -e "source run_all.sql"
-- It drops and recreates the wiki_time_machine database, takes about fifteen seconds,
-- and ends with "N / N checks passed".
--
-- Keep --abort-source-on-error: without it the client carries on after an error inside a
-- sourced file and exits with status 0, so a broken build would look like a good one.

-- The tables: page and revision (Wikipedia's way), article (WITH SYSTEM VERSIONING).
source sql/01_schema.sql
-- The 13,354 downloaded revisions, into page and revision.
source build/load_revisions.sql
-- The history of `article`, written with Wikipedia's save times.
source sql/02_build_history.sql
-- The time machine in SQL: AS OF, BETWEEN, FROM ... TO, ALL.
source sql/03_time_machine.sql
-- History made by the server: a table that is edited, vandalised, restored, deleted.
source sql/04_lab.sql
-- Checks; a failed one stops the run with an error.
source sql/90_checks.sql
