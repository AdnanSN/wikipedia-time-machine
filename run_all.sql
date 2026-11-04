-- run_all.sql: build the database from the downloaded revisions and run every demo and check.
--
-- From the repository folder, first generate the data file, then run this script:
--     python scripts/build_sql.py
--     mariadb -u root -p --table --abort-source-on-error -e "source run_all.sql"
-- It drops and recreates the wiki_time_machine database, takes about ten seconds, and
-- ends with "N / N checks passed".
--
-- Keep --abort-source-on-error: without it the client carries on after an error inside a
-- sourced file and exits with status 0, so a broken build would look like a good one.

source sql/01_schema.sql
source build/load_revisions.sql
source sql/02_build_history.sql
source sql/03_time_machine.sql
source sql/90_checks.sql
