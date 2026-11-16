-- upstream/mdev-29674-wrong-results.sql
--
-- FOR SYSTEM_TIME AS OF silently returns no rows after history was imported into a
-- table partitioned BY SYSTEM_TIME INTERVAL ... AUTO.
--
-- A consequence of MDEV-29674 ("History modification inserts records into a wrong
-- partition without warning") that the report does not mention: wrong results.
-- Found while loading Wikipedia's revision history; reduced here to two rows.
-- Self-contained: uses its own database and no data.
--
--     mariadb -u root -p --table --force -e "source upstream/mdev-29674-wrong-results.sql"
--
-- (--force, because the script goes on after the errors it is there to show.)
-- Observed on MariaDB 12.3.3 (Windows 11, x64). CI runs it on 10.11, 11.4 and 12.3
-- and keeps the output; see upstream/README.md.

DROP DATABASE IF EXISTS wtm_mdev_29674;
CREATE DATABASE wtm_mdev_29674;
USE wtm_mdev_29674;
SET time_zone = '+00:00';
SELECT VERSION();

-- 1. Yearly history partitions from 2020 on, created as they are needed.
CREATE TABLE t (
  id INT PRIMARY KEY,
  v  VARCHAR(20),
  row_start TIMESTAMP(6) GENERATED ALWAYS AS ROW START,
  row_end   TIMESTAMP(6) GENERATED ALWAYS AS ROW END,
  PERIOD FOR SYSTEM_TIME (row_start, row_end)
) WITH SYSTEM VERSIONING
  PARTITION BY SYSTEM_TIME INTERVAL 1 YEAR STARTS '2020-01-01 00:00:00' AUTO;

-- 2. Migrate one row's history into it, as system_versioning_insert_history is meant for:
--    a version that was current from mid-2021 to mid-2023, and the current version.
SET @@session.system_versioning_insert_history = 1;
INSERT INTO t (id, v, row_start, row_end) VALUES (1, 'as of 2022', '2021-06-01 00:00:00', '2023-06-01 00:00:00');
INSERT INTO t (id, v, row_start)          VALUES (1, 'current',    '2023-06-01 00:00:00');
SET @@session.system_versioning_insert_history = 0;

-- 3. So far everything is right. The history row sits in p0 (the year 2020), because
--    the INSERT created no partition for 2023; p0 is the last history partition, and
--    the last one may hold later rows. CHECK TABLE agrees.
SELECT 'before any DML' AS step, v FROM t FOR SYSTEM_TIME AS OF TIMESTAMP '2022-07-01 00:00:00';
SELECT PARTITION_NAME, PARTITION_DESCRIPTION FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = 'wtm_mdev_29674' AND TABLE_NAME = 't' ORDER BY PARTITION_ORDINAL_POSITION;
CHECK TABLE t;

-- 4. One ordinary UPDATE. It needs a history partition for the current year, so AUTO
--    creates all the missing ones. AUTO never moves existing rows.
UPDATE t SET v = 'edited today' WHERE id = 1;

-- 5. The row of 2022 is still in p0, which is now no longer the last history partition,
--    so partition pruning skips it for any moment after 2020.
--    EXPECTED: one row, 'as of 2022'.   ACTUAL on 12.3.3: no rows, no warning.
SELECT 'after one UPDATE' AS step, COUNT(*) AS rows_as_of_2022 FROM t FOR SYSTEM_TIME AS OF TIMESTAMP '2022-07-01 00:00:00';
EXPLAIN PARTITIONS SELECT v FROM t FOR SYSTEM_TIME AS OF TIMESTAMP '2022-07-01 00:00:00';
--    The row is still there: without pruning by row_end it is found.
SELECT 'FOR SYSTEM_TIME ALL' AS step, v, row_start, row_end FROM t FOR SYSTEM_TIME ALL ORDER BY row_start;
SELECT COUNT(*) AS rows_in_p0 FROM t PARTITION (p0);

-- 6. Now, and only now, CHECK TABLE reports it, and REPAIR TABLE fixes it.
CHECK TABLE t;
REPAIR TABLE t;
SELECT 'after REPAIR TABLE' AS step, v FROM t FOR SYSTEM_TIME AS OF TIMESTAMP '2022-07-01 00:00:00';

-- 7. What avoids it: declare the history partitions before loading. Then the same
--    INSERT places each row by its row_end.
CREATE TABLE t2 (
  id INT PRIMARY KEY,
  v  VARCHAR(20),
  row_start TIMESTAMP(6) GENERATED ALWAYS AS ROW START,
  row_end   TIMESTAMP(6) GENERATED ALWAYS AS ROW END,
  PERIOD FOR SYSTEM_TIME (row_start, row_end)
) WITH SYSTEM VERSIONING
  PARTITION BY SYSTEM_TIME INTERVAL 1 YEAR STARTS '2020-01-01 00:00:00' AUTO PARTITIONS 8;
SET @@session.system_versioning_insert_history = 1;
INSERT INTO t2 (id, v, row_start, row_end) VALUES (1, 'as of 2022', '2021-06-01 00:00:00', '2023-06-01 00:00:00');
INSERT INTO t2 (id, v, row_start)          VALUES (1, 'current',    '2023-06-01 00:00:00');
SET @@session.system_versioning_insert_history = 0;
UPDATE t2 SET v = 'edited today' WHERE id = 1;
SELECT 'partitions declared first' AS step, v FROM t2 FOR SYSTEM_TIME AS OF TIMESTAMP '2022-07-01 00:00:00';
SELECT COUNT(*) AS rows_in_p3_the_year_2023 FROM t2 PARTITION (p3);
CHECK TABLE t2;

DROP DATABASE wtm_mdev_29674;
