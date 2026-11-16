-- experiments/time-models/run.sql: four ways to give the history its dates, built side
-- by side from the same revisions and measured (milestone M4). The write-up is
-- docs/decisions/0001-time-model.md.
--
--     python scripts/run_sql.py experiments/time-models/run.sql
--
-- Needs the database built by run_all.sql. Works in its own database, wtm_models, which
-- it drops at the end; it only reads wiki_time_machine. Takes a few minutes: two of the
-- models replay all 13,354 revisions one statement at a time, several times over.
--
--   A   replay the revisions; the system period records when WE imported them
--   A'  replay them with the session clock set to each save time
--   B   write the history rows directly (system_versioning_insert_history): our choice
--   C   the save times as an application-time period, next to system versioning
--
-- Parts: 1 the four tables, 2 how each is loaded, 3 load time and size, 4 the same
--        question asked of each, 5 what each lets go wrong, 6 what only C can answer.

DROP DATABASE IF EXISTS wtm_models;
CREATE DATABASE wtm_models CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE wtm_models;
SET time_zone = '+00:00';
source experiments/harness.sql

SELECT VERSION() AS mariadb, @@version_compile_os AS os,
       ROUND(@@innodb_buffer_pool_size / 1048576) AS buffer_pool_mb,
       @@global.secure_timestamp AS secure_timestamp, @runs AS timed_runs_per_statement;


-- ===========================================================================
-- 1. The four tables
-- ===========================================================================
-- They are created as empty patterns; each load makes a fresh copy with
-- CREATE OR REPLACE TABLE ... LIKE, so that every timed load starts from nothing.

-- A and A': the article table, plus the save time as an ordinary column. Model A needs
-- that column, because its system period will hold the time of the import; in A' it
-- only repeats row_start. The extra index serves A's "as it stood at t" query.
CREATE TABLE pattern_replayed (
  page_id    INT UNSIGNED NOT NULL,
  title      VARCHAR(255) NOT NULL,
  rev_id     INT UNSIGNED NOT NULL,
  editor     VARCHAR(255) NULL,
  summary    TEXT NULL,
  minor_edit BOOLEAN NOT NULL,
  len        INT UNSIGNED NULL,
  sha1       CHAR(40) NULL,
  tags       VARCHAR(1024) NULL,
  content    MEDIUMTEXT NULL,
  saved_at   DATETIME(6) NOT NULL,
  row_start  TIMESTAMP(6) GENERATED ALWAYS AS ROW START,
  row_end    TIMESTAMP(6) GENERATED ALWAYS AS ROW END,
  PERIOD FOR SYSTEM_TIME (row_start, row_end),
  PRIMARY KEY (page_id),
  KEY saved (page_id, saved_at)
) WITH SYSTEM VERSIONING;

-- B: exactly the table the project uses.
CREATE TABLE pattern_direct LIKE wiki_time_machine.article;

-- C: bitemporal. valid_time says when Wikipedia showed this text; the system period,
-- left to the server, says when OUR database held this row. DATETIME, not TIMESTAMP:
-- an application-time period is not tied to the TIMESTAMP range, so it can hold dates
-- before 1970 and its "no end" is simply the largest DATETIME.
-- WITHOUT OVERLAPS makes the server refuse two versions of one article at one moment.
CREATE TABLE pattern_bitemporal (
  page_id    INT UNSIGNED NOT NULL,
  title      VARCHAR(255) NOT NULL,
  rev_id     INT UNSIGNED NOT NULL,
  editor     VARCHAR(255) NULL,
  summary    TEXT NULL,
  minor_edit BOOLEAN NOT NULL,
  len        INT UNSIGNED NULL,
  sha1       CHAR(40) NULL,
  tags       VARCHAR(1024) NULL,
  content    MEDIUMTEXT NULL,
  valid_from DATETIME(6) NOT NULL,
  valid_to   DATETIME(6) NOT NULL,
  PERIOD FOR valid_time (valid_from, valid_to),
  PRIMARY KEY (page_id, valid_time WITHOUT OVERLAPS)
) WITH SYSTEM VERSIONING;

SET @no_end = TIMESTAMP '9999-12-31 23:59:59.999999';


-- ===========================================================================
-- 2. How each model is loaded
-- ===========================================================================

DELIMITER //

-- A and A': every revision in the order it was saved, one statement each, as a live
-- wiki would have run them: the first revision of an article is an INSERT, every later
-- one an UPDATE of that row. With p_set_clock the session clock is first set to the
-- revision's save time, so the server stamps the version with it (A'); without, the
-- server stamps the time of the import (A).
CREATE OR REPLACE PROCEDURE replay(IN p_set_clock BOOLEAN)
BEGIN
  DECLARE done BOOLEAN DEFAULT FALSE;
  DECLARE v_rev, v_page INT UNSIGNED;
  DECLARE v_saved DATETIME(6);
  DECLARE v_first BOOLEAN;
  DECLARE revisions CURSOR FOR
    SELECT rev_id, rev_page, saved_at,
           ROW_NUMBER() OVER (PARTITION BY rev_page ORDER BY saved_at) = 1
    FROM wiki_time_machine.revision_period
    ORDER BY saved_at, rev_id;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

  OPEN revisions;
  each_revision: LOOP
    FETCH revisions INTO v_rev, v_page, v_saved, v_first;
    IF done THEN LEAVE each_revision; END IF;
    IF p_set_clock THEN
      -- saved_at carries microseconds for saves made in the same second (see
      -- sql/02_build_history.sql), and so does the clock set here.
      SET timestamp = UNIX_TIMESTAMP(v_saved);
    END IF;
    IF v_first THEN
      INSERT INTO replayed (page_id, title, rev_id, editor, summary, minor_edit, len, sha1, tags, content, saved_at)
      SELECT r.rev_page, p.page_title, r.rev_id, r.rev_actor, r.rev_comment, r.rev_minor_edit,
             r.rev_len, r.rev_sha1, r.rev_tags, r.content, v_saved
      FROM wiki_time_machine.revision AS r
      JOIN wiki_time_machine.page AS p ON p.page_id = r.rev_page
      WHERE r.rev_id = v_rev;
    ELSE
      UPDATE replayed AS a
      JOIN wiki_time_machine.revision AS r ON r.rev_id = v_rev
      SET a.rev_id = r.rev_id, a.editor = r.rev_actor, a.summary = r.rev_comment,
          a.minor_edit = r.rev_minor_edit, a.len = r.rev_len, a.sha1 = r.rev_sha1,
          a.tags = r.rev_tags, a.content = r.content, a.saved_at = v_saved
      WHERE a.page_id = v_page;
    END IF;
  END LOOP;
  CLOSE revisions;
  SET timestamp = DEFAULT;
END //

-- B: two statements, as in sql/02_build_history.sql.
CREATE OR REPLACE PROCEDURE load_direct()
BEGIN
  SET @@session.system_versioning_insert_history = 1;
  INSERT INTO direct (page_id, title, rev_id, editor, summary, minor_edit, len, sha1, tags,
                      content, row_start, row_end)
  SELECT r.rev_page, p.page_title, r.rev_id, r.rev_actor, r.rev_comment, r.rev_minor_edit,
         r.rev_len, r.rev_sha1, r.rev_tags, r.content, v.saved_at, v.replaced_at
  FROM wiki_time_machine.revision AS r
  JOIN wiki_time_machine.page AS p ON p.page_id = r.rev_page
  JOIN wiki_time_machine.revision_period AS v ON v.rev_id = r.rev_id
  WHERE v.replaced_at IS NOT NULL;
  INSERT INTO direct (page_id, title, rev_id, editor, summary, minor_edit, len, sha1, tags,
                      content, row_start)
  SELECT r.rev_page, p.page_title, r.rev_id, r.rev_actor, r.rev_comment, r.rev_minor_edit,
         r.rev_len, r.rev_sha1, r.rev_tags, r.content, v.saved_at
  FROM wiki_time_machine.revision AS r
  JOIN wiki_time_machine.page AS p ON p.page_id = r.rev_page
  JOIN wiki_time_machine.revision_period AS v ON v.rev_id = r.rev_id
  WHERE v.replaced_at IS NULL;
  SET @@session.system_versioning_insert_history = 0;
END //

-- C: one ordinary INSERT. Every revision is a current row; its dates are data.
CREATE OR REPLACE PROCEDURE load_bitemporal()
BEGIN
  INSERT INTO bitemporal (page_id, title, rev_id, editor, summary, minor_edit, len, sha1, tags,
                          content, valid_from, valid_to)
  SELECT r.rev_page, p.page_title, r.rev_id, r.rev_actor, r.rev_comment, r.rev_minor_edit,
         r.rev_len, r.rev_sha1, r.rev_tags, r.content, v.saved_at, COALESCE(v.replaced_at, @no_end)
  FROM wiki_time_machine.revision AS r
  JOIN wiki_time_machine.page AS p ON p.page_id = r.rev_page
  JOIN wiki_time_machine.revision_period AS v ON v.rev_id = r.rev_id;
END //

-- Load each model from nothing, LEAST(@runs, 5) times, and time each load. A replay is
-- wrapped in one transaction; otherwise the time would mostly be the 13,354 commits.
CREATE OR REPLACE PROCEDURE time_loads()
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE started DATETIME(6);
  WHILE i <= LEAST(@runs, 5) DO
    CREATE OR REPLACE TABLE replayed LIKE pattern_replayed;
    SET started = SYSDATE(6);
    START TRANSACTION;
    CALL replay(FALSE);
    COMMIT;
    INSERT INTO timing (topic, label, run, ms)
    VALUES ('load', 'A   replay, import-time stamps (13,354 statements)', i, TIMESTAMPDIFF(MICROSECOND, started, SYSDATE(6)) / 1000);
    -- Keep the last A for the questions below; A' is replayed into the same name.
    DROP TABLE IF EXISTS model_a;
    RENAME TABLE replayed TO model_a;

    CREATE OR REPLACE TABLE replayed LIKE pattern_replayed;
    SET started = SYSDATE(6);
    START TRANSACTION;
    CALL replay(TRUE);
    COMMIT;
    INSERT INTO timing (topic, label, run, ms)
    VALUES ('load', 'A''  replay with the session clock set (13,354 statements)', i, TIMESTAMPDIFF(MICROSECOND, started, SYSDATE(6)) / 1000);
    DROP TABLE IF EXISTS model_a_clock;
    RENAME TABLE replayed TO model_a_clock;

    CREATE OR REPLACE TABLE direct LIKE pattern_direct;
    SET started = SYSDATE(6);
    CALL load_direct();
    INSERT INTO timing (topic, label, run, ms)
    VALUES ('load', 'B   history rows written directly (2 statements)', i, TIMESTAMPDIFF(MICROSECOND, started, SYSDATE(6)) / 1000);

    CREATE OR REPLACE TABLE bitemporal LIKE pattern_bitemporal;
    SET started = SYSDATE(6);
    CALL load_bitemporal();
    INSERT INTO timing (topic, label, run, ms)
    VALUES ('load', 'C   application-time period (1 statement)', i, TIMESTAMPDIFF(MICROSECOND, started, SYSDATE(6)) / 1000);
    SET i = i + 1;
  END WHILE;
END //

DELIMITER ;


-- ===========================================================================
-- 3. Load time and size
-- ===========================================================================

CALL time_loads();
CALL report('load');

ANALYZE TABLE model_a, model_a_clock, direct, bitemporal;

-- What each table holds and how big it is. In A, A' and B the old versions are history
-- rows, invisible to an ordinary query; in C all 13,354 are current rows.
SELECT 'A' AS model, (SELECT COUNT(*) FROM model_a) AS rows_a_plain_query_sees,
       (SELECT COUNT(*) FROM model_a FOR SYSTEM_TIME ALL) AS rows_in_all,
       (SELECT ROUND((DATA_LENGTH + INDEX_LENGTH) / 1048576, 1) FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = 'wtm_models' AND TABLE_NAME = 'model_a') AS mb_on_disk
UNION ALL
SELECT 'A''', (SELECT COUNT(*) FROM model_a_clock), (SELECT COUNT(*) FROM model_a_clock FOR SYSTEM_TIME ALL),
       (SELECT ROUND((DATA_LENGTH + INDEX_LENGTH) / 1048576, 1) FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = 'wtm_models' AND TABLE_NAME = 'model_a_clock')
UNION ALL
SELECT 'B', (SELECT COUNT(*) FROM direct), (SELECT COUNT(*) FROM direct FOR SYSTEM_TIME ALL),
       (SELECT ROUND((DATA_LENGTH + INDEX_LENGTH) / 1048576, 1) FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = 'wtm_models' AND TABLE_NAME = 'direct')
UNION ALL
SELECT 'C', (SELECT COUNT(*) FROM bitemporal), (SELECT COUNT(*) FROM bitemporal FOR SYSTEM_TIME ALL),
       (SELECT ROUND((DATA_LENGTH + INDEX_LENGTH) / 1048576, 1) FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = 'wtm_models' AND TABLE_NAME = 'bitemporal');

-- 3b. The shape a replay leaves behind. A and A' hold the same rows as B in about twice
--     the space. A replay puts each version where the index has room at that moment,
--     and until its transaction commits the server cannot reuse the space of the texts
--     it replaced. The timed replays above ran in one transaction each, which is the
--     worst case; a live site commits every edit. So: one more replay of A', this time
--     with every edit in a transaction of its own, and then a rebuild of that table.
CREATE OR REPLACE TABLE replayed LIKE pattern_replayed;
SET @started = SYSDATE(6);
CALL replay(TRUE);
SET @live_seconds = ROUND(TIMESTAMPDIFF(MICROSECOND, @started, SYSDATE(6)) / 1e6, 1);
RENAME TABLE replayed TO model_a_live;
ANALYZE TABLE model_a_live;

CREATE OR REPLACE TABLE shape (id INT AUTO_INCREMENT PRIMARY KEY, how_it_was_built VARCHAR(90), mb_on_disk DOUBLE);
INSERT INTO shape (how_it_was_built, mb_on_disk)
SELECT 'B: loaded with two statements', ROUND((DATA_LENGTH + INDEX_LENGTH) / 1048576, 1)
FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'wtm_models' AND TABLE_NAME = 'direct';
INSERT INTO shape (how_it_was_built, mb_on_disk)
SELECT 'A'': replayed inside one transaction', ROUND((DATA_LENGTH + INDEX_LENGTH) / 1048576, 1)
FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'wtm_models' AND TABLE_NAME = 'model_a_clock';
INSERT INTO shape (how_it_was_built, mb_on_disk)
SELECT CONCAT('A'': replayed, one transaction per edit (', @live_seconds, ' s)'), ROUND((DATA_LENGTH + INDEX_LENGTH) / 1048576, 1)
FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'wtm_models' AND TABLE_NAME = 'model_a_live';

--     The extra size is not only disk space. The rows of a replayed table are spread
--     over more pages, and with the default 128 MB buffer pool, smaller than either
--     table, a query that reads all of them fetches those pages from disk. Counted
--     here with the server's Innodb_buffer_pool_reads, around one run of the query
--     (after one run that is not counted, as for the timings).
CREATE OR REPLACE TABLE disk_reads (id INT AUTO_INCREMENT PRIMARY KEY, label VARCHAR(120), pages_read_from_disk BIGINT);
DELIMITER //
CREATE OR REPLACE PROCEDURE count_disk_reads(IN p_label VARCHAR(120), IN p_sql TEXT)
BEGIN
  DECLARE before_run BIGINT;
  SET @counted_sql = p_sql;
  PREPARE counted FROM @counted_sql;
  EXECUTE counted;
  SELECT VARIABLE_VALUE INTO before_run FROM information_schema.GLOBAL_STATUS
   WHERE VARIABLE_NAME = 'INNODB_BUFFER_POOL_READS';
  EXECUTE counted;
  INSERT INTO disk_reads (label, pages_read_from_disk)
  SELECT p_label, VARIABLE_VALUE - before_run FROM information_schema.GLOBAL_STATUS
   WHERE VARIABLE_NAME = 'INNODB_BUFFER_POOL_READS';
  DEALLOCATE PREPARE counted;
END //
DELIMITER ;

CALL measure('shape', 'B: all articles as of 2010, no text',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM direct FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'");
CALL count_disk_reads('B: all articles as of 2010, no text',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM direct FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'");
CALL measure('shape', 'A'' replayed, one transaction per edit: the same',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM model_a_live FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'");
CALL count_disk_reads('A'' replayed, one transaction per edit: the same',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM model_a_live FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'");

--     OPTIMIZE TABLE is the usual way to rebuild a table. On a system-versioned table
--     it is refused like any other ALTER until the session allows it:
OPTIMIZE TABLE model_a_live;
SET @@session.system_versioning_alter_history = KEEP;
SET @started = SYSDATE(6);
ALTER TABLE model_a_live FORCE;
SET @rebuild_seconds = ROUND(TIMESTAMPDIFF(MICROSECOND, @started, SYSDATE(6)) / 1e6, 1);
SET @@session.system_versioning_alter_history = ERROR;
ANALYZE TABLE model_a_live;
INSERT INTO shape (how_it_was_built, mb_on_disk)
SELECT CONCAT('the same table after ALTER TABLE ... FORCE (', @rebuild_seconds, ' s)'), ROUND((DATA_LENGTH + INDEX_LENGTH) / 1048576, 1)
FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'wtm_models' AND TABLE_NAME = 'model_a_live';
CALL measure('shape', 'A'' after the rebuild: the same',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM model_a_live FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'");
CALL count_disk_reads('A'' after the rebuild: the same',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM model_a_live FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'");

SELECT how_it_was_built, mb_on_disk,
       ROUND(100 * mb_on_disk / (SELECT mb_on_disk FROM shape WHERE id = 1)) AS percent_of_b
FROM shape ORDER BY id;
CALL report('shape');
SELECT label, pages_read_from_disk FROM disk_reads ORDER BY id;

INSERT INTO check_result (test, pass)
SELECT 'the rebuild keeps every version and every date of the replayed table',
       (SELECT COUNT(*) FROM model_a_live FOR SYSTEM_TIME ALL) = (SELECT COUNT(*) FROM direct FOR SYSTEM_TIME ALL)
   AND NOT EXISTS (SELECT 1 FROM direct FOR SYSTEM_TIME ALL AS b
                     LEFT JOIN model_a_live FOR SYSTEM_TIME ALL AS a
                       ON a.page_id = b.page_id AND a.row_end = b.row_end
                    WHERE a.rev_id IS NULL OR a.rev_id <> b.rev_id OR a.row_start <> b.row_start);

-- Where the dates ended up. In A the system period is the minute of the import.
SELECT 'A' AS model, MIN(row_start) AS earliest_row_start, MAX(row_start) AS latest_row_start FROM model_a FOR SYSTEM_TIME ALL
UNION ALL
SELECT 'A''', MIN(row_start), MAX(row_start) FROM model_a_clock FOR SYSTEM_TIME ALL
UNION ALL
SELECT 'B', MIN(row_start), MAX(row_start) FROM direct FOR SYSTEM_TIME ALL
UNION ALL
SELECT 'C (valid_from)', MIN(valid_from), MAX(valid_from) FROM bitemporal;

-- A' and B are two routes to the same table: not one version differs in its revision,
-- its start or its end.
INSERT INTO check_result (test, pass)
SELECT 'A'' (replay with the clock set) and B (direct write) build identical histories',
       (SELECT COUNT(*) FROM model_a_clock FOR SYSTEM_TIME ALL) = (SELECT COUNT(*) FROM direct FOR SYSTEM_TIME ALL)
   AND NOT EXISTS (SELECT 1 FROM direct FOR SYSTEM_TIME ALL AS b
                     LEFT JOIN model_a_clock FOR SYSTEM_TIME ALL AS a
                       ON a.page_id = b.page_id AND a.row_end = b.row_end
                    WHERE a.rev_id IS NULL OR a.rev_id <> b.rev_id OR a.row_start <> b.row_start
                       OR NOT a.sha1 <=> b.sha1);

INSERT INTO check_result (test, pass)
SELECT 'every model holds all 13,354 revisions',
       (SELECT COUNT(*) FROM model_a FOR SYSTEM_TIME ALL) = (SELECT COUNT(*) FROM wiki_time_machine.revision)
   AND (SELECT COUNT(*) FROM direct FOR SYSTEM_TIME ALL) = (SELECT COUNT(*) FROM wiki_time_machine.revision)
   AND (SELECT COUNT(*) FROM bitemporal) = (SELECT COUNT(*) FROM wiki_time_machine.revision);


-- ===========================================================================
-- 4. The same question, asked of each model
-- ===========================================================================

-- "The MariaDB article as it stood on 1 June 2010." All four must name revision 365034244.
-- A: the system period is useless for this, so the query is the revision-table query:
--    newest save before the moment, over every version.
SELECT 'A' AS model, rev_id, saved_at FROM model_a FOR SYSTEM_TIME ALL
WHERE page_id = 24960699 AND saved_at <= TIMESTAMP '2010-06-01 00:00:00'
ORDER BY saved_at DESC LIMIT 1;
-- A' and B: the clause the feature exists for.
SELECT 'A''' AS model, rev_id, row_start FROM model_a_clock FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'
WHERE page_id = 24960699;
SELECT 'B' AS model, rev_id, row_start FROM direct FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'
WHERE page_id = 24960699;
-- C: a WHERE on the application period. FOR SYSTEM_TIME plays no part.
SELECT 'C' AS model, rev_id, valid_from FROM bitemporal
WHERE page_id = 24960699 AND valid_from <= TIMESTAMP '2010-06-01 00:00:00' AND valid_to > TIMESTAMP '2010-06-01 00:00:00';

-- All four agree, for every article at 27 moments.
CREATE OR REPLACE TABLE probe (at_time DATETIME(6) PRIMARY KEY);
INSERT INTO probe SELECT TIMESTAMP(CONCAT(seq, '-01-01 00:30:00')) FROM seq_2001_to_2027;

CREATE OR REPLACE TABLE answer (model VARCHAR(4), at_time DATETIME(6), page_id INT UNSIGNED, rev_id INT UNSIGNED,
                                PRIMARY KEY (model, at_time, page_id));
INSERT INTO answer
SELECT 'ref', m.at_time, a.page_id, a.rev_id FROM probe AS m
JOIN wiki_time_machine.article FOR SYSTEM_TIME ALL AS a ON a.row_start <= m.at_time AND m.at_time < a.row_end;
INSERT INTO answer
SELECT 'A', at_time, page_id, rev_id
FROM (SELECT m.at_time, a.page_id, a.rev_id,
             ROW_NUMBER() OVER (PARTITION BY m.at_time, a.page_id ORDER BY a.saved_at DESC) AS newest
      FROM probe AS m JOIN model_a FOR SYSTEM_TIME ALL AS a ON a.saved_at <= m.at_time) AS ranked
WHERE newest = 1;
INSERT INTO answer
SELECT 'A''', m.at_time, a.page_id, a.rev_id FROM probe AS m
JOIN model_a_clock FOR SYSTEM_TIME ALL AS a ON a.row_start <= m.at_time AND m.at_time < a.row_end;
INSERT INTO answer
SELECT 'B', m.at_time, a.page_id, a.rev_id FROM probe AS m
JOIN direct FOR SYSTEM_TIME ALL AS a ON a.row_start <= m.at_time AND m.at_time < a.row_end;
INSERT INTO answer
SELECT 'C', m.at_time, a.page_id, a.rev_id FROM probe AS m
JOIN bitemporal AS a ON a.valid_from <= m.at_time AND m.at_time < a.valid_to;

SELECT model, COUNT(*) AS answers FROM answer GROUP BY model ORDER BY model;

INSERT INTO check_result (test, pass)
SELECT 'all four models give the same revision for every article at 27 moments',
       NOT EXISTS (SELECT 1 FROM answer AS r
                     JOIN (SELECT 'A' AS model UNION ALL SELECT 'A''' UNION ALL SELECT 'B' UNION ALL SELECT 'C') AS models
                     LEFT JOIN answer AS a ON a.model = models.model AND a.at_time = r.at_time AND a.page_id = r.page_id
                    WHERE r.model = 'ref' AND (a.rev_id IS NULL OR a.rev_id <> r.rev_id))
   AND (SELECT COUNT(DISTINCT n) FROM (SELECT COUNT(*) AS n FROM answer GROUP BY model) AS counts) = 1;

-- How long each model takes to answer. Early and late moments differ, because a lookup
-- reads forward from the moment through every later version (experiments/growth, part 6);
-- the lines marked "first row" add ORDER BY ... LIMIT 1, which stops at the first.
CALL measure('ask', 'A   one article with text as of 2010',
  "SELECT LENGTH(content) INTO @a FROM model_a FOR SYSTEM_TIME ALL WHERE page_id = 24960699 AND saved_at <= TIMESTAMP '2010-06-01 00:00:00' ORDER BY saved_at DESC LIMIT 1");
CALL measure('ask', 'A''  one article with text as of 2010',
  "SELECT LENGTH(content) INTO @a FROM model_a_clock FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00' WHERE page_id = 24960699");
CALL measure('ask', 'B   one article with text as of 2010',
  "SELECT LENGTH(content) INTO @a FROM direct FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00' WHERE page_id = 24960699");
CALL measure('ask', 'B   the same, first row',
  "SELECT LENGTH(content) INTO @a FROM direct FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00' WHERE page_id = 24960699 ORDER BY row_end LIMIT 1");
CALL measure('ask', 'C   one article with text as of 2010',
  "SELECT LENGTH(content) INTO @a FROM bitemporal WHERE page_id = 24960699 AND valid_from <= TIMESTAMP '2010-06-01 00:00:00' AND valid_to > TIMESTAMP '2010-06-01 00:00:00'");
CALL measure('ask', 'C   the same, first row',
  "SELECT LENGTH(content) INTO @a FROM bitemporal WHERE page_id = 24960699 AND valid_from <= TIMESTAMP '2010-06-01 00:00:00' AND valid_to > TIMESTAMP '2010-06-01 00:00:00' ORDER BY valid_to LIMIT 1");
CALL measure('ask', 'A   all articles as of 2010, no text',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM (SELECT len, ROW_NUMBER() OVER (PARTITION BY page_id ORDER BY saved_at DESC) AS newest FROM model_a FOR SYSTEM_TIME ALL WHERE saved_at <= TIMESTAMP '2010-06-01 00:00:00') AS ranked WHERE newest = 1");
CALL measure('ask', 'A''  all articles as of 2010, no text',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM model_a_clock FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'");
CALL measure('ask', 'B   all articles as of 2010, no text',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM direct FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'");
CALL measure('ask', 'C   all articles as of 2010, no text',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM bitemporal WHERE valid_from <= TIMESTAMP '2010-06-01 00:00:00' AND valid_to > TIMESTAMP '2010-06-01 00:00:00'");
CALL measure('ask', 'A   the current articles (30 rows), no text',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM model_a");
CALL measure('ask', 'B   the current articles (30 rows), no text',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM direct");
CALL measure('ask', 'C   the current articles (30 of 13,354 rows), no text',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM bitemporal WHERE valid_to = TIMESTAMP '9999-12-31 23:59:59.999999'");
CALL report('ask');


-- ===========================================================================
-- 5. What each model lets go wrong
-- ===========================================================================
-- Tried on three made-up revisions of a made-up article 1: 'a' and 'b' saved in the
-- same second, 'c' five seconds later.

-- 5a. A', naively: the clock set to Wikipedia's whole seconds. The first UPDATE happens
--     at the same instant as the INSERT, so version 'a' would start and end together.
--     The server drops it: no error, no warning, and the history is one version short.
CREATE TABLE same_second LIKE pattern_replayed;
SET timestamp = UNIX_TIMESTAMP('2020-01-01 12:00:00');
INSERT INTO same_second (page_id, title, rev_id, minor_edit, content, saved_at) VALUES (1, 'x', 1, 0, 'a', '2020-01-01 12:00:00');
UPDATE same_second SET rev_id = 2, content = 'b' WHERE page_id = 1;
SET timestamp = UNIX_TIMESTAMP('2020-01-01 12:00:05');
UPDATE same_second SET rev_id = 3, content = 'c' WHERE page_id = 1;
SET timestamp = DEFAULT;
INSERT INTO finding (topic, what, observed)
SELECT 'wrong', 'A'' with whole seconds: 3 revisions replayed, versions kept',
       CONCAT(COUNT(*), ' (', GROUP_CONCAT(content ORDER BY row_start), ')')
FROM same_second FOR SYSTEM_TIME ALL;

-- 5b. B accepts what it is given. Two versions of one row that overlap in time go in
--     without complaint, and AS OF then returns two rows for one primary key.
CREATE TABLE overlap_b LIKE pattern_direct;
SET @@session.system_versioning_insert_history = 1;
CALL attempt("INSERT INTO overlap_b (page_id, title, rev_id, minor_edit, row_start, row_end) VALUES (1, 'x', 1, 0, '2020-01-01 00:00:00', '2021-01-01 00:00:00')");
CALL attempt("INSERT INTO overlap_b (page_id, title, rev_id, minor_edit, row_start, row_end) VALUES (1, 'x', 2, 0, '2020-06-01 00:00:00', '2022-01-01 00:00:00')");
INSERT INTO finding (topic, what, observed)
SELECT 'wrong', 'B: a second version overlapping the first by seven months', @attempt_message;
INSERT INTO finding (topic, what, observed)
SELECT 'wrong', 'B: rows AS OF 2020-07-01 for that one primary key', COUNT(*)
FROM overlap_b FOR SYSTEM_TIME AS OF TIMESTAMP '2020-07-01 00:00:00';
--     What B does refuse: a version that ends when it starts, or before.
CALL attempt("INSERT INTO overlap_b (page_id, title, rev_id, minor_edit, row_start, row_end) VALUES (2, 'y', 1, 0, '2020-01-01 00:00:00', '2020-01-01 00:00:00')");
INSERT INTO finding (topic, what, observed)
SELECT 'wrong', 'B: a version whose start equals its end', CONCAT('error ', @attempt_error, ': ', @attempt_message);
SET @@session.system_versioning_insert_history = 0;
--     And without the setting, the period columns cannot be written at all.
CALL attempt("INSERT INTO overlap_b (page_id, title, rev_id, minor_edit, row_start, row_end) VALUES (3, 'z', 1, 0, '2020-01-01 00:00:00', '2021-01-01 00:00:00')");
INSERT INTO finding (topic, what, observed)
SELECT 'wrong', 'B without system_versioning_insert_history', CONCAT('error ', @attempt_error, ': ', @attempt_message);

-- 5c. C refuses the overlap itself: WITHOUT OVERLAPS is a constraint the server keeps.
CREATE TABLE overlap_c LIKE pattern_bitemporal;
CALL attempt("INSERT INTO overlap_c (page_id, title, rev_id, minor_edit, valid_from, valid_to) VALUES (1, 'x', 1, 0, '2020-01-01 00:00:00', '2021-01-01 00:00:00')");
CALL attempt("INSERT INTO overlap_c (page_id, title, rev_id, minor_edit, valid_from, valid_to) VALUES (1, 'x', 2, 0, '2020-06-01 00:00:00', '2022-01-01 00:00:00')");
INSERT INTO finding (topic, what, observed)
SELECT 'wrong', 'C: the same overlapping version', CONCAT('error ', @attempt_error, ': ', @attempt_message);
CALL attempt("INSERT INTO overlap_c (page_id, title, rev_id, minor_edit, valid_from, valid_to) VALUES (2, 'y', 1, 0, '2020-01-01 00:00:00', '2020-01-01 00:00:00')");
INSERT INTO finding (topic, what, observed)
SELECT 'wrong', 'C: a version whose start equals its end', CONCAT('error ', @attempt_error, ': ', @attempt_message);

SELECT what, observed FROM finding WHERE topic = 'wrong' ORDER BY id;

INSERT INTO check_result (test, pass)
SELECT 'the application-time table refuses overlapping versions; the direct write does not',
       (SELECT observed FROM finding WHERE what = 'B: a second version overlapping the first by seven months') = 'accepted'
   AND (SELECT observed FROM finding WHERE what = 'C: the same overlapping version') LIKE 'error 1062%';


-- ===========================================================================
-- 6. What only the bitemporal table can answer
-- ===========================================================================
-- The other models know one time: when Wikipedia saved a text. C also knows when OUR
-- copy learned it. To give that second time something to say, the table is filled the
-- way a mirror of Wikipedia would be: synchronised once, then again later, then
-- corrected. The clock is set by hand at each step so that the output is repeatable.

CREATE TABLE mirror LIKE pattern_bitemporal;

-- 15 January 2026, first synchronisation: everything saved before 2026.
SET timestamp = UNIX_TIMESTAMP('2026-01-15 03:00:00');
INSERT INTO mirror (page_id, title, rev_id, editor, summary, minor_edit, len, sha1, tags, content, valid_from, valid_to)
SELECT rev_page, page_title, rev_id, rev_actor, rev_comment, rev_minor_edit, rev_len, rev_sha1, rev_tags, content,
       saved_at, IF(replaced_at < TIMESTAMP '2026-01-01 00:00:00', replaced_at, @no_end)
FROM (SELECT r.*, p.page_title, v.saved_at, v.replaced_at
      FROM wiki_time_machine.revision AS r
      JOIN wiki_time_machine.page AS p ON p.page_id = r.rev_page
      JOIN wiki_time_machine.revision_period AS v ON v.rev_id = r.rev_id) AS known
WHERE saved_at < TIMESTAMP '2026-01-01 00:00:00';

-- 1 November 2026, second synchronisation: the edits of 2026, one statement each.
-- In an application-time table an edit is UPDATE ... FOR PORTION OF: "from this moment
-- on, the article is this". The server cuts the old row short at that moment and adds
-- a row for the rest; nobody writes the old row's end date by hand.
DELIMITER //
CREATE OR REPLACE PROCEDURE second_sync()
BEGIN
  DECLARE done BOOLEAN DEFAULT FALSE;
  DECLARE v_rev, v_page, v_len INT UNSIGNED;
  DECLARE v_saved DATETIME(6);
  DECLARE v_editor VARCHAR(255);
  DECLARE v_summary TEXT;
  DECLARE v_minor BOOLEAN;
  DECLARE v_sha1 CHAR(40);
  DECLARE v_tags VARCHAR(1024);
  DECLARE v_content MEDIUMTEXT;
  DECLARE edits CURSOR FOR
    SELECT rev_id, rev_page, saved_at FROM wiki_time_machine.revision_period
    WHERE saved_at >= TIMESTAMP '2026-01-01 00:00:00' ORDER BY saved_at, rev_id;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;
  OPEN edits;
  each_edit: LOOP
    FETCH edits INTO v_rev, v_page, v_saved;
    IF done THEN LEAVE each_edit; END IF;
    SELECT rev_actor, rev_comment, rev_minor_edit, rev_len, rev_sha1, rev_tags, content
      INTO v_editor, v_summary, v_minor, v_len, v_sha1, v_tags, v_content
      FROM wiki_time_machine.revision WHERE rev_id = v_rev;
    UPDATE mirror FOR PORTION OF valid_time FROM v_saved TO @no_end
       SET rev_id = v_rev, editor = v_editor, summary = v_summary, minor_edit = v_minor,
           len = v_len, sha1 = v_sha1, tags = v_tags, content = v_content
     WHERE page_id = v_page;
  END LOOP;
  CLOSE edits;
END //
DELIMITER ;

SET timestamp = UNIX_TIMESTAMP('2026-11-01 03:00:00');
CALL second_sync();

-- 5 November 2026, a correction to the past: the 11-second vandalism of 28 November
-- 2022 ("Bob the Builder University Bremen") is hidden, as Wikipedia's administrators
-- hide revisions. In C a past version is an ordinary row, so this is an ordinary UPDATE.
SET timestamp = UNIX_TIMESTAMP('2026-11-05 09:00:00');
UPDATE mirror SET content = NULL, summary = 'text hidden' WHERE rev_id = 1124412138;
SET timestamp = DEFAULT;

INSERT INTO check_result (test, pass)
SELECT 'two synchronisations and a correction leave the mirror equal to the one-statement load',
       (SELECT COUNT(*) FROM mirror) = (SELECT COUNT(*) FROM bitemporal)
   AND NOT EXISTS (SELECT 1 FROM bitemporal AS b
                     LEFT JOIN mirror AS m ON m.page_id = b.page_id AND m.valid_from = b.valid_from
                    WHERE m.rev_id IS NULL OR m.rev_id <> b.rev_id OR m.valid_to <> b.valid_to
                       OR (b.rev_id <> 1124412138 AND NOT m.sha1 <=> SHA1(m.content)));

-- 6a. Two times in one question: "what did the MariaDB article say on 1 June 2026?",
--     asked of the mirror as it stood in March (after the first synchronisation) and
--     as it stands now. In March the mirror could only offer the last text of 2025,
--     believing it still current; now it knows the edits made since.
SELECT 'the mirror as of 1 March 2026' AS according_to, rev_id, valid_from AS saved_on_wikipedia,
       IF(valid_to = @no_end, 'believed still current', valid_to) AS replaced
FROM mirror FOR SYSTEM_TIME AS OF TIMESTAMP '2026-03-01 00:00:00'
WHERE page_id = 24960699 AND valid_from <= TIMESTAMP '2026-06-01 00:00:00' AND valid_to > TIMESTAMP '2026-06-01 00:00:00'
UNION ALL
SELECT 'the mirror now', rev_id, valid_from, IF(valid_to = @no_end, 'still current', valid_to)
FROM mirror
WHERE page_id = 24960699 AND valid_from <= TIMESTAMP '2026-06-01 00:00:00' AND valid_to > TIMESTAMP '2026-06-01 00:00:00';

-- 6b. The correction is on record too: what the mirror said about the vandal's 11
--     seconds before and after the text was hidden.
SELECT 'the mirror as of 2 November 2026' AS according_to, rev_id,
       IF(content IS NULL, 'no text', CONCAT(CHAR_LENGTH(content), ' characters, with "Bob the Builder University" in them: ',
          IF(content LIKE '%Bob the Builder University%', 'yes', 'no'))) AS the_text, summary
FROM mirror FOR SYSTEM_TIME AS OF TIMESTAMP '2026-11-02 00:00:00'
WHERE page_id = 104185 AND valid_from <= TIMESTAMP '2022-11-28 20:04:45' AND valid_to > TIMESTAMP '2022-11-28 20:04:45'
UNION ALL
SELECT 'the mirror now', rev_id,
       IF(content IS NULL, 'no text', CONCAT(CHAR_LENGTH(content), ' characters')), summary
FROM mirror
WHERE page_id = 104185 AND valid_from <= TIMESTAMP '2022-11-28 20:04:45' AND valid_to > TIMESTAMP '2022-11-28 20:04:45';

-- 6c. The system period as a log of the mirror itself: what each step did to it.
SELECT ROW_START AS mirror_changed_at, COUNT(*) AS row_versions_written
FROM mirror FOR SYSTEM_TIME ALL
GROUP BY ROW_START
ORDER BY ROW_START;

INSERT INTO check_result (test, pass)
SELECT 'the mirror of March believed the last revision of 2025 was still current on 1 June 2026',
       (SELECT valid_to FROM mirror FOR SYSTEM_TIME AS OF TIMESTAMP '2026-03-01 00:00:00'
         WHERE page_id = 24960699 AND valid_from <= TIMESTAMP '2026-06-01 00:00:00'
           AND valid_to > TIMESTAMP '2026-06-01 00:00:00') = @no_end
   AND (SELECT rev_id FROM mirror FOR SYSTEM_TIME AS OF TIMESTAMP '2026-03-01 00:00:00'
         WHERE page_id = 24960699 AND valid_from <= TIMESTAMP '2026-06-01 00:00:00'
           AND valid_to > TIMESTAMP '2026-06-01 00:00:00')
    <> (SELECT rev_id FROM mirror
         WHERE page_id = 24960699 AND valid_from <= TIMESTAMP '2026-06-01 00:00:00'
           AND valid_to > TIMESTAMP '2026-06-01 00:00:00');

INSERT INTO check_result (test, pass)
SELECT 'the hidden text is gone from the mirror now and still readable in the mirror of 2 November',
       (SELECT content FROM mirror WHERE rev_id = 1124412138) IS NULL
   AND (SELECT content FROM mirror FOR SYSTEM_TIME AS OF TIMESTAMP '2026-11-02 00:00:00'
         WHERE rev_id = 1124412138) LIKE '%Bob the Builder University Bremen%';


-- ===========================================================================
-- Done
-- ===========================================================================
CALL finish_checks('time-model');

DELIMITER //
BEGIN NOT ATOMIC
  IF COALESCE(@keep, 0) = 0 THEN
    DROP DATABASE wtm_models;
  END IF;
END //
DELIMITER ;
