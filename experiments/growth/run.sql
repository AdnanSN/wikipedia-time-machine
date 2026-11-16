-- experiments/growth/run.sql: how the versioned table grows, and what partitioning by
-- SYSTEM_TIME does about it (milestone M3). The write-up is docs/growth-and-partitioning.md.
--
--     python scripts/run_sql.py experiments/growth/run.sql
--     (or: mariadb -u root -p --table --abort-source-on-error -e "source experiments/growth/run.sql")
--
-- Needs the database built by run_all.sql. Works in its own database, wtm_growth, which
-- it drops at the end; it only reads wiki_time_machine. It makes four copies of the
-- history, so it needs about 1 GB of free disk space while it runs, and one to two
-- minutes with the default 7 timed runs per statement.
--
-- Parts: 1 growth, 2 the same history stored smaller, 3 partitioning by SYSTEM_TIME,
--        4 the trap in loading dated history into partitions, 5 removing old history,
--        6 what growth does to AS OF.

DROP DATABASE IF EXISTS wtm_growth;
CREATE DATABASE wtm_growth CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE wtm_growth;
SET time_zone = '+00:00';
source experiments/harness.sql

-- Where and how this ran. Timings mean nothing without it.
SELECT VERSION() AS mariadb, @@version_compile_os AS os, @@version_compile_machine AS cpu_type,
       ROUND(@@innodb_buffer_pool_size / 1048576) AS buffer_pool_mb, @@innodb_page_size AS page_bytes,
       @runs AS timed_runs_per_statement;


-- ===========================================================================
-- 1. Growth
-- ===========================================================================

-- 1a. Current rows against history rows. A query without FOR SYSTEM_TIME sees only the
--     first line; the table holds both.
SELECT IF(row_end > CURRENT_TIMESTAMP(6), 'current', 'history') AS rows_are,
       COUNT(*) AS versions, ROUND(SUM(len) / 1e6, 1) AS mb_of_text, ROUND(AVG(len)) AS avg_bytes_each
FROM wiki_time_machine.article FOR SYSTEM_TIME ALL
GROUP BY rows_are;

-- 1b. On disk. TABLE_ROWS is InnoDB's estimate; with rows this large it is far from the
--     real count, so do not size a history from it.
ANALYZE TABLE wiki_time_machine.article;
SELECT TABLE_ROWS AS rows_estimated,
       (SELECT COUNT(*) FROM wiki_time_machine.article FOR SYSTEM_TIME ALL) AS rows_counted,
       ROUND(DATA_LENGTH / 1048576, 1) AS data_mb, ROUND(INDEX_LENGTH / 1048576, 1) AS index_mb,
       ROUND(DATA_FREE / 1048576, 1) AS free_mb
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'wiki_time_machine' AND TABLE_NAME = 'article';

-- 1c. What one edit costs. System versioning keeps the whole old row, so every edit
--     stores the whole article again, however little it changed. (The change in length
--     understates how much text an edit touched, but it shows the proportion.)
SELECT COUNT(*) AS edits,
       ROUND(AVG(len)) AS bytes_stored_per_edit,
       ROUND(AVG(ABS(change_in_length))) AS bytes_of_length_changed_per_edit,
       ROUND(SUM(len) / SUM(ABS(change_in_length))) AS stored_for_each_byte_changed
FROM (SELECT len, CAST(len AS SIGNED)
                  - CAST(LAG(len) OVER (PARTITION BY page_id ORDER BY row_start) AS SIGNED)
                    AS change_in_length
      FROM wiki_time_machine.article FOR SYSTEM_TIME ALL) AS edit
WHERE change_in_length IS NOT NULL;

-- 1d. Year by year: the history as it accumulated.
SELECT year, edits, SUM(edits) OVER (ORDER BY year) AS versions_so_far,
       mb_saved, ROUND(SUM(mb_saved) OVER (ORDER BY year), 1) AS mb_so_far
FROM (SELECT YEAR(row_start) AS year, COUNT(*) AS edits, ROUND(SUM(len) / 1e6, 2) AS mb_saved
      FROM wiki_time_machine.article FOR SYSTEM_TIME ALL
      GROUP BY YEAR(row_start)) AS per_year
ORDER BY year;

-- 1e. Versions whose text is byte-for-byte a text the same article had before: reverts.
--     A row-versioned table stores each of them in full again.
SELECT COUNT(*) AS versions, SUM(seen_before) AS texts_seen_before,
       ROUND(100 * SUM(seen_before) / COUNT(*), 1) AS percent_of_versions,
       ROUND(SUM(IF(seen_before, len, 0)) / 1e6, 1) AS mb_stored_again
FROM (SELECT len, ROW_NUMBER() OVER (PARTITION BY page_id, sha1 ORDER BY row_start) > 1 AS seen_before
      FROM wiki_time_machine.article FOR SYSTEM_TIME ALL) AS version;


-- ===========================================================================
-- 2. The same history, stored smaller
-- ===========================================================================

-- A system-versioned table, history included, is copied with one INSERT ... SELECT once
-- system_versioning_insert_history lets the statement write row_start and row_end.
-- (This is also what mariadb-dump --dump-history relies on when a dump is restored.)
SET @@session.system_versioning_insert_history = 1;
-- ALTER TABLE is refused on a system-versioned table unless this is set to KEEP.
SET @@session.system_versioning_alter_history = KEEP;

-- 2a. Column compression: MariaDB compresses each text on its own (zlib).
CREATE TABLE article_compressed LIKE wiki_time_machine.article;
ALTER TABLE article_compressed MODIFY content MEDIUMTEXT COMPRESSED NULL;
INSERT INTO article_compressed SELECT * FROM wiki_time_machine.article FOR SYSTEM_TIME ALL;

-- 2b. Text kept apart: the versioned row keeps only the SHA-1 of its text, and each
--     distinct text is stored once in an ordinary table. This is the shape of
--     MediaWiki's own storage (revision -> content -> text), with the server keeping
--     the versions. A reverted-to text costs 40 bytes instead of the whole article.
CREATE TABLE article_slim LIKE wiki_time_machine.article;
ALTER TABLE article_slim DROP COLUMN content;
INSERT INTO article_slim
SELECT page_id, title, rev_id, editor, summary, minor_edit, len, sha1, tags, row_start, row_end
FROM wiki_time_machine.article FOR SYSTEM_TIME ALL;

-- The primary key is a counter, so new texts are appended at the end of the table;
-- with the SHA-1 as primary key they would land all over it and leave its pages half
-- empty. sha1 has the same character set as article.sha1 on purpose: a join between
-- two character sets cannot use an index.
CREATE TABLE article_text (
  text_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  sha1    CHAR(40) NOT NULL,
  content MEDIUMTEXT COMPRESSED NOT NULL,
  UNIQUE KEY sha1 (sha1)
);
-- INSERT IGNORE: a text that is already there is skipped by the unique key.
INSERT IGNORE INTO article_text (sha1, content)
SELECT sha1, content FROM wiki_time_machine.article FOR SYSTEM_TIME ALL WHERE content IS NOT NULL;

ANALYZE TABLE article_compressed, article_slim, article_text;

CREATE OR REPLACE TABLE storage (design VARCHAR(60), versions INT, data_mb DOUBLE, index_mb DOUBLE);
INSERT INTO storage
SELECT 'article: one full text per version', (SELECT COUNT(*) FROM wiki_time_machine.article FOR SYSTEM_TIME ALL),
       DATA_LENGTH / 1048576, INDEX_LENGTH / 1048576
FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'wiki_time_machine' AND TABLE_NAME = 'article';
INSERT INTO storage
SELECT 'content MEDIUMTEXT COMPRESSED', (SELECT COUNT(*) FROM article_compressed FOR SYSTEM_TIME ALL),
       DATA_LENGTH / 1048576, INDEX_LENGTH / 1048576
FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'wtm_growth' AND TABLE_NAME = 'article_compressed';
INSERT INTO storage
SELECT 'versioned row + each distinct text once', (SELECT COUNT(*) FROM article_slim FOR SYSTEM_TIME ALL),
       SUM(DATA_LENGTH) / 1048576, SUM(INDEX_LENGTH) / 1048576
FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'wtm_growth' AND TABLE_NAME IN ('article_slim', 'article_text');

SELECT design, versions, ROUND(data_mb + index_mb, 1) AS mb_on_disk,
       ROUND(100 * (data_mb + index_mb) / (SELECT data_mb + index_mb FROM storage LIMIT 1)) AS percent_of_plain
FROM storage;

SELECT (SELECT COUNT(*) FROM article_text) AS distinct_texts_stored,
       (SELECT COUNT(*) FROM article_slim FOR SYSTEM_TIME ALL) AS versions_pointing_at_them;

-- Both smaller designs still give back every text exactly.
INSERT INTO check_result (test, pass)
SELECT 'the compressed copy returns every text unchanged (SHA-1 of every version)',
       (SELECT COUNT(*) FROM article_compressed FOR SYSTEM_TIME ALL) = (SELECT COUNT(*) FROM wiki_time_machine.article FOR SYSTEM_TIME ALL)
   AND NOT EXISTS (SELECT 1 FROM article_compressed FOR SYSTEM_TIME ALL WHERE SHA1(content) <> sha1);

INSERT INTO check_result (test, pass)
SELECT 'the split copy returns every text unchanged, as of any moment',
       NOT EXISTS (SELECT 1 FROM article_slim FOR SYSTEM_TIME ALL AS s
                     LEFT JOIN article_text AS t USING (sha1)
                    WHERE t.sha1 IS NULL OR SHA1(t.content) <> s.sha1)
   AND (SELECT t.content FROM article_slim FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00' AS s
          JOIN article_text AS t USING (sha1) WHERE s.title = 'MariaDB')
     = (SELECT content FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'
         WHERE title = 'MariaDB');

-- What the smaller designs cost when reading: one article with its text at an early
-- moment, and a search through the current texts.
CALL measure('storage', 'plain: MariaDB article as of 2012, with text',
  "SELECT LENGTH(content) INTO @a FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2012-06-01 00:00:00' WHERE page_id = 24960699 ORDER BY row_end LIMIT 1");
CALL measure('storage', 'compressed: MariaDB article as of 2012, with text',
  "SELECT LENGTH(content) INTO @a FROM article_compressed FOR SYSTEM_TIME AS OF TIMESTAMP '2012-06-01 00:00:00' WHERE page_id = 24960699 ORDER BY row_end LIMIT 1");
CALL measure('storage', 'split: MariaDB article as of 2012, joined to its text',
  "SELECT LENGTH(t.content) INTO @a FROM article_slim FOR SYSTEM_TIME AS OF TIMESTAMP '2012-06-01 00:00:00' AS s JOIN article_text AS t USING (sha1) WHERE s.page_id = 24960699 ORDER BY s.row_end LIMIT 1");
CALL measure('storage', 'plain: every version listed, no text (13,354 rows)',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM wiki_time_machine.article FOR SYSTEM_TIME ALL");
CALL measure('storage', 'compressed: every version listed, no text',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM article_compressed FOR SYSTEM_TIME ALL");
CALL measure('storage', 'split: every version listed, no text',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM article_slim FOR SYSTEM_TIME ALL");
CALL report('storage');


-- ===========================================================================
-- 3. Partitioning by SYSTEM_TIME
-- ===========================================================================

-- One partition per year of history and one for the current rows. The history
-- partitions are all declared here, before any row is loaded: part 4 shows what
-- happens otherwise. 26 = the 25 years from 2002 to 2026 and the current partition;
-- AUTO lets the server add a partition for each year after that when it is first needed.
CREATE TABLE article_part LIKE wiki_time_machine.article;
ALTER TABLE article_part
  PARTITION BY SYSTEM_TIME INTERVAL 1 YEAR STARTS '2002-01-01 00:00:00' AUTO PARTITIONS 26;
INSERT INTO article_part SELECT * FROM wiki_time_machine.article FOR SYSTEM_TIME ALL;

-- 3a. Where the rows went. A history row belongs to the partition of the time it
--     stopped being current, its row_end. information_schema only estimates the rows,
--     so count them, partition by partition.
CREATE OR REPLACE TABLE partition_rows (
  table_name VARCHAR(64), partition_name VARCHAR(64), position INT,
  described_as VARCHAR(40),          -- as information_schema puts it: a date, or CURRENT
  history_until DATETIME NULL,       -- the same as a date; NULL where it is not one
  rows_counted INT, data_mb DOUBLE, PRIMARY KEY (table_name, partition_name));

DELIMITER //
CREATE OR REPLACE PROCEDURE count_partitions(IN p_table VARCHAR(64))
BEGIN
  DECLARE done BOOLEAN DEFAULT FALSE;
  DECLARE v_name VARCHAR(64);
  DECLARE names CURSOR FOR
    SELECT PARTITION_NAME FROM information_schema.PARTITIONS
     WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = p_table ORDER BY PARTITION_ORDINAL_POSITION;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;
  DELETE FROM partition_rows WHERE table_name = p_table;
  INSERT INTO partition_rows (table_name, partition_name, position, described_as, history_until, data_mb)
    SELECT p_table, PARTITION_NAME, PARTITION_ORDINAL_POSITION, PARTITION_DESCRIPTION,
           IF(PARTITION_DESCRIPTION REGEXP '^[0-9]{4}-', PARTITION_DESCRIPTION, NULL), DATA_LENGTH / 1048576
      FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = p_table;
  OPEN names;
  each_partition: LOOP
    FETCH names INTO v_name;
    IF done THEN LEAVE each_partition; END IF;
    -- Reading one partition by name returns its rows, history rows included.
    -- The names come from the server's own catalogue, never from a user.
    SET @count_sql = CONCAT('SELECT COUNT(*) INTO @partition_count FROM `', p_table, '` PARTITION (`', v_name, '`)');
    PREPARE counting FROM @count_sql;
    EXECUTE counting;
    DEALLOCATE PREPARE counting;
    UPDATE partition_rows SET rows_counted = @partition_count
     WHERE table_name = p_table AND partition_name = v_name;
  END LOOP;
  CLOSE names;
END //
DELIMITER ;

ANALYZE TABLE article_part;
CALL count_partitions('article_part');
SELECT partition_name, described_as AS holds_history_until, rows_counted, ROUND(data_mb, 1) AS data_mb
FROM partition_rows WHERE table_name = 'article_part' ORDER BY position;

INSERT INTO check_result (test, pass)
SELECT 'every history row is in the partition of the year it ended, the current rows in theirs',
       NOT EXISTS (
         SELECT 1
           FROM (SELECT YEAR(row_end) AS year_ended, COUNT(*) AS versions
                   FROM article_part FOR SYSTEM_TIME ALL
                  WHERE row_end <= CURRENT_TIMESTAMP(6) GROUP BY YEAR(row_end)) AS by_year
           LEFT JOIN partition_rows AS p
             ON p.table_name = 'article_part' AND YEAR(p.history_until - INTERVAL 1 DAY) = by_year.year_ended
          WHERE p.rows_counted IS NULL OR p.rows_counted <> by_year.versions)
   AND (SELECT rows_counted FROM partition_rows
         WHERE table_name = 'article_part' AND described_as = 'CURRENT')
     = (SELECT COUNT(*) FROM wiki_time_machine.article);

-- The partitioned table answers every AS OF question as the plain one does: all
-- articles, at half past midnight on 1 January of every year.
CREATE OR REPLACE TABLE probe (at_time DATETIME(6) PRIMARY KEY);
INSERT INTO probe SELECT TIMESTAMP(CONCAT(seq, '-01-01 00:30:00')) FROM seq_2001_to_2027;

INSERT INTO check_result (test, pass)
SELECT 'the partitioned table gives the same answer to AS OF as the plain table (27 moments)',
       (SELECT COUNT(*) FROM probe AS m JOIN article_part FOR SYSTEM_TIME ALL AS a
                 ON a.row_start <= m.at_time AND m.at_time < a.row_end)
     = (SELECT COUNT(*) FROM probe AS m JOIN wiki_time_machine.article FOR SYSTEM_TIME ALL AS a
                 ON a.row_start <= m.at_time AND m.at_time < a.row_end)
   AND NOT EXISTS (
         SELECT 1 FROM probe AS m
           JOIN wiki_time_machine.article FOR SYSTEM_TIME ALL AS a
             ON a.row_start <= m.at_time AND m.at_time < a.row_end
           LEFT JOIN article_part FOR SYSTEM_TIME ALL AS b
             ON b.page_id = a.page_id AND b.row_start <= m.at_time AND m.at_time < b.row_end
          WHERE b.rev_id IS NULL OR b.rev_id <> a.rev_id);

CHECK TABLE article_part;

-- 3b. Which partitions a query has to open (the `partitions` column).
--     Current rows only: one partition.
EXPLAIN PARTITIONS SELECT COUNT(*) FROM article_part WHERE len > 20000;
--     As of a moment: the partition of that year, every later one, and the current one.
--     Earlier years are pruned: a version that ended before the moment cannot be the answer.
EXPLAIN PARTITIONS SELECT COUNT(*) FROM article_part FOR SYSTEM_TIME AS OF TIMESTAMP '2020-06-01 00:00:00';
--     A range of history: the year the range starts in and, again, every later one.
--     The partitions are cut by when versions ended; a version that was current during
--     2010 may have ended in any later year, so only the earlier years can be skipped.
EXPLAIN PARTITIONS SELECT COUNT(*) FROM article_part
                   FOR SYSTEM_TIME FROM TIMESTAMP '2010-03-01 00:00:00' TO TIMESTAMP '2010-09-01 00:00:00';
--     Everything: every partition.
EXPLAIN PARTITIONS SELECT COUNT(*) FROM article_part FOR SYSTEM_TIME ALL;

-- 3c. The same statements against the plain and the partitioned table.
CALL measure('partitioning', 'plain: count the long current articles (no index helps)',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM wiki_time_machine.article WHERE len > 20000");
CALL measure('partitioning', 'partitioned: count the long current articles (no index helps)',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM article_part WHERE len > 20000");
CALL measure('partitioning', 'plain: search the current texts for a word',
  "SELECT COUNT(*) INTO @a FROM wiki_time_machine.article WHERE content LIKE '%MariaDB%'");
CALL measure('partitioning', 'partitioned: search the current texts for a word',
  "SELECT COUNT(*) INTO @a FROM article_part WHERE content LIKE '%MariaDB%'");
CALL measure('partitioning', 'plain: one current article by its key',
  "SELECT len INTO @a FROM wiki_time_machine.article WHERE page_id = 24960699");
CALL measure('partitioning', 'partitioned: one current article by its key',
  "SELECT len INTO @a FROM article_part WHERE page_id = 24960699");
CALL measure('partitioning', 'plain: all articles as of 2020',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2020-06-01 00:00:00'");
CALL measure('partitioning', 'partitioned: all articles as of 2020',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM article_part FOR SYSTEM_TIME AS OF TIMESTAMP '2020-06-01 00:00:00'");
CALL measure('partitioning', 'plain: all articles as of 2006',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2006-06-01 00:00:00'");
CALL measure('partitioning', 'partitioned: all articles as of 2006',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM article_part FOR SYSTEM_TIME AS OF TIMESTAMP '2006-06-01 00:00:00'");
CALL measure('partitioning', 'plain: one article as of 2012, with text',
  "SELECT LENGTH(content) INTO @a FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2012-06-01 00:00:00' WHERE page_id = 24960699 ORDER BY row_end LIMIT 1");
CALL measure('partitioning', 'partitioned: one article as of 2012, with text',
  "SELECT LENGTH(content) INTO @a FROM article_part FOR SYSTEM_TIME AS OF TIMESTAMP '2012-06-01 00:00:00' WHERE page_id = 24960699 ORDER BY row_end LIMIT 1");
CALL measure('partitioning', 'plain: every version counted',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM wiki_time_machine.article FOR SYSTEM_TIME ALL");
CALL measure('partitioning', 'partitioned: every version counted',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM article_part FOR SYSTEM_TIME ALL");
CALL report('partitioning');


-- ===========================================================================
-- 4. The trap: dated history, and partitions that do not exist yet
-- ===========================================================================
-- The slim tables below carry no text, so that this part is quick.

-- 4a. The obvious way to ask for yearly partitions: name the interval and its start,
--     say AUTO, and let the server make them. Right after CREATE there are two
--     partitions: one for the year 2002 and one for the current rows.
CREATE TABLE trap (
  page_id   INT UNSIGNED NOT NULL,
  rev_id    INT UNSIGNED NOT NULL,
  row_start TIMESTAMP(6) GENERATED ALWAYS AS ROW START,
  row_end   TIMESTAMP(6) GENERATED ALWAYS AS ROW END,
  PERIOD FOR SYSTEM_TIME (row_start, row_end),
  PRIMARY KEY (page_id)
) WITH SYSTEM VERSIONING
  PARTITION BY SYSTEM_TIME INTERVAL 1 YEAR STARTS '2002-01-01 00:00:00' AUTO;

--     Load 24 years of history with their real dates, as 02_build_history.sql does.
INSERT INTO trap SELECT page_id, rev_id, row_start, row_end FROM wiki_time_machine.article FOR SYSTEM_TIME ALL;

--     AUTO did not act: an INSERT never creates history partitions, not even one that
--     writes history. Every history row is in the one partition there is, far past
--     the year it was made for. The server says nothing, and queries are still right.
CALL count_partitions('trap');
INSERT INTO finding (topic, what, observed)
SELECT 'trap', 'partitions after loading 2002-2026 into INTERVAL 1 YEAR ... AUTO', COUNT(*) FROM partition_rows WHERE table_name = 'trap';
INSERT INTO finding (topic, what, observed)
SELECT 'trap', 'history rows in the partition for 2002 (12 ended that year)', rows_counted
FROM partition_rows WHERE table_name = 'trap' AND position = 1;
INSERT INTO finding (topic, what, observed)
SELECT 'trap', 'articles AS OF 2010-06-01 after the load (27 is right)', COUNT(*)
FROM trap FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00';

--     Now the table goes live: one ordinary UPDATE, of one row.
UPDATE trap SET rev_id = rev_id WHERE page_id = 24960699;

--     That UPDATE needed a history partition for the current year, so AUTO created
--     every missing year at once. It did not move the rows already there. The 2002
--     partition still holds 24 years of history, and from now on the server skips it
--     for any moment after 2002, as it is entitled to: the time machine returns nothing.
CALL count_partitions('trap');
INSERT INTO finding (topic, what, observed)
SELECT 'trap', 'partitions after one UPDATE', COUNT(*) FROM partition_rows WHERE table_name = 'trap';
INSERT INTO finding (topic, what, observed)
SELECT 'trap', 'history rows still in the partition for 2002', rows_counted
FROM partition_rows WHERE table_name = 'trap' AND position = 1;
INSERT INTO finding (topic, what, observed)
SELECT 'trap', 'articles AS OF 2010-06-01 after one UPDATE (27 is right)', COUNT(*)
FROM trap FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00';
INSERT INTO finding (topic, what, observed)
SELECT 'trap', 'versions under FOR SYSTEM_TIME ALL after one UPDATE (13,355 is right)', COUNT(*)
FROM trap FOR SYSTEM_TIME ALL;

--     Only now can the server tell that something is wrong.
CHECK TABLE trap;
--     REPAIR TABLE moves the rows to the partitions they belong in.
REPAIR TABLE trap;
CALL count_partitions('trap');
INSERT INTO finding (topic, what, observed)
SELECT 'trap', 'history rows in the partition for 2002 after REPAIR TABLE (12 is right)', rows_counted
FROM partition_rows WHERE table_name = 'trap' AND position = 1;
INSERT INTO finding (topic, what, observed)
SELECT 'trap', 'articles AS OF 2010-06-01 after REPAIR TABLE (27 is right)', COUNT(*)
FROM trap FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00';

-- 4b. A second way out, from the documentation: adding a history partition by hand
--     makes the server move the rows that belong after the last one.
CREATE TABLE added_later (
  page_id   INT UNSIGNED NOT NULL,
  rev_id    INT UNSIGNED NOT NULL,
  row_start TIMESTAMP(6) GENERATED ALWAYS AS ROW START,
  row_end   TIMESTAMP(6) GENERATED ALWAYS AS ROW END,
  PERIOD FOR SYSTEM_TIME (row_start, row_end),
  PRIMARY KEY (page_id)
) WITH SYSTEM VERSIONING
  PARTITION BY SYSTEM_TIME INTERVAL 1 YEAR STARTS '2002-01-01 00:00:00'
  (PARTITION p2002 HISTORY, PARTITION pcur CURRENT);
INSERT INTO added_later SELECT page_id, rev_id, row_start, row_end FROM wiki_time_machine.article FOR SYSTEM_TIME ALL;
ALTER TABLE added_later ADD PARTITION (PARTITION p2003 HISTORY, PARTITION p2004 HISTORY);
CALL count_partitions('added_later');
INSERT INTO finding (topic, what, observed)
SELECT 'trap', 'ADD PARTITION for 2003 and 2004: rows left in 2002, then in 2003, then in 2004 and later',
       GROUP_CONCAT(rows_counted ORDER BY position SEPARATOR ', ')
FROM partition_rows WHERE table_name = 'added_later' AND described_as <> 'CURRENT';

-- 4c. Rotation by row count instead of by time has the same weakness, and its own:
--     the server switches partitions between statements, so one bulk INSERT puts
--     everything into the first partition, whatever the LIMIT says.
CREATE TABLE by_count (
  page_id   INT UNSIGNED NOT NULL,
  rev_id    INT UNSIGNED NOT NULL,
  row_start TIMESTAMP(6) GENERATED ALWAYS AS ROW START,
  row_end   TIMESTAMP(6) GENERATED ALWAYS AS ROW END,
  PERIOD FOR SYSTEM_TIME (row_start, row_end),
  PRIMARY KEY (page_id)
) WITH SYSTEM VERSIONING
  PARTITION BY SYSTEM_TIME LIMIT 2000 PARTITIONS 8;
INSERT INTO by_count SELECT page_id, rev_id, row_start, row_end FROM wiki_time_machine.article FOR SYSTEM_TIME ALL;
CALL count_partitions('by_count');
INSERT INTO finding (topic, what, observed)
SELECT 'trap', 'LIMIT 2000 with 7 history partitions, one bulk load: rows per history partition',
       GROUP_CONCAT(rows_counted ORDER BY position SEPARATOR ', ')
FROM partition_rows
WHERE table_name = 'by_count' AND position < (SELECT MAX(position) FROM partition_rows WHERE table_name = 'by_count');

SELECT what, observed FROM finding WHERE topic = 'trap' ORDER BY id;

-- What must hold on every version: the load itself loses nothing, and after the repair
-- the table is right again.
INSERT INTO check_result (test, pass)
SELECT 'before the first UPDATE, the table loaded into too few partitions still answers AS OF correctly',
       (SELECT observed FROM finding WHERE what LIKE 'articles AS OF 2010-06-01 after the load%') = 27;
INSERT INTO check_result (test, pass)
SELECT 'after REPAIR TABLE it answers AS OF correctly again',
       (SELECT observed FROM finding WHERE what LIKE 'articles AS OF 2010-06-01 after REPAIR TABLE%') = 27;


-- ===========================================================================
-- 5. Removing old history
-- ===========================================================================
-- Two ways to forget everything that ended before 2015, each on its own copy of the
-- partitioned table. The copies are rebuilt before every timed run.

CREATE OR REPLACE TABLE removal (way VARCHAR(40), run INT, ms DOUBLE, versions_left INT, mb_left DOUBLE,
                                 mb_free_inside DOUBLE, partitions_left INT);

DELIMITER //
CREATE OR REPLACE PROCEDURE try_removals()
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE started DATETIME(6);
  WHILE i <= LEAST(@runs, 3) DO
    -- Way 1: DELETE HISTORY removes the versions that ended before the moment, row by row.
    CREATE OR REPLACE TABLE trimmed_by_delete LIKE article_part;
    INSERT INTO trimmed_by_delete SELECT * FROM article_part FOR SYSTEM_TIME ALL;
    SET started = SYSDATE(6);
    DELETE HISTORY FROM trimmed_by_delete BEFORE SYSTEM_TIME '2015-01-01 00:00:00';
    SET @ms = TIMESTAMPDIFF(MICROSECOND, started, SYSDATE(6)) / 1000;
    ANALYZE TABLE trimmed_by_delete;
    INSERT INTO removal
    SELECT 'DELETE HISTORY ... BEFORE', i, @ms, (SELECT COUNT(*) FROM trimmed_by_delete FOR SYSTEM_TIME ALL),
           SUM(DATA_LENGTH) / 1048576, SUM(DATA_FREE) / 1048576, COUNT(*)
      FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'trimmed_by_delete';

    -- Way 2: DROP PARTITION removes whole years at once, files and all.
    CREATE OR REPLACE TABLE trimmed_by_drop LIKE article_part;
    INSERT INTO trimmed_by_drop SELECT * FROM article_part FOR SYSTEM_TIME ALL;
    SET started = SYSDATE(6);
    ALTER TABLE trimmed_by_drop DROP PARTITION p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12;
    SET @ms = TIMESTAMPDIFF(MICROSECOND, started, SYSDATE(6)) / 1000;
    ANALYZE TABLE trimmed_by_drop;
    INSERT INTO removal
    SELECT 'DROP PARTITION (13 years)', i, @ms, (SELECT COUNT(*) FROM trimmed_by_drop FOR SYSTEM_TIME ALL),
           SUM(DATA_LENGTH) / 1048576, SUM(DATA_FREE) / 1048576, COUNT(*)
      FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'trimmed_by_drop';
    SET i = i + 1;
  END WHILE;
END //
DELIMITER ;

CALL try_removals();

SELECT way, COUNT(*) AS runs, ROUND(MIN(ms)) AS fastest_ms, ROUND(MAX(ms)) AS slowest_ms,
       MAX(versions_left) AS versions_left, ROUND(MAX(mb_left), 1) AS mb_still_allocated,
       ROUND(MAX(mb_free_inside), 1) AS mb_free_inside_the_files, MAX(partitions_left) AS partitions_left
FROM removal GROUP BY way ORDER BY way;

-- Both leave the same versions.
INSERT INTO check_result (test, pass)
SELECT 'DELETE HISTORY and DROP PARTITION leave the same versions behind',
       (SELECT COUNT(*) FROM trimmed_by_delete FOR SYSTEM_TIME ALL) = (SELECT COUNT(*) FROM trimmed_by_drop FOR SYSTEM_TIME ALL)
   AND (SELECT COUNT(*) FROM trimmed_by_delete FOR SYSTEM_TIME ALL)
     = (SELECT COUNT(*) FROM article_part FOR SYSTEM_TIME ALL WHERE row_end >= TIMESTAMP '2015-01-01 00:00:00');

-- What is forgotten is forgotten silently. Before 2015 the trimmed table has no rows to
-- return, and a query cannot tell "the article did not exist" from "its history was
-- removed": it gets the same empty answer, without a warning.
SELECT (SELECT COUNT(*) FROM article_part FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00') AS articles_as_of_2010_before,
       (SELECT COUNT(*) FROM trimmed_by_delete FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00') AS after_delete_history,
       (SELECT COUNT(*) FROM trimmed_by_drop FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00') AS after_drop_partition,
       (SELECT COUNT(*) FROM trimmed_by_drop FOR SYSTEM_TIME AS OF TIMESTAMP '2020-06-01 00:00:00') AS as_of_2020_still_complete;


-- ===========================================================================
-- 6. What growth does to AS OF
-- ===========================================================================
-- "This article as it stood at t" is a lookup by primary key, and the primary key is
-- (page_id, row_end). The server starts at the first version that ended after t and,
-- because it cannot know that the versions of one row never overlap, reads on to the
-- newest one. The earlier the moment, the more versions it reads to return one.
-- ORDER BY row_end LIMIT 1 tells it what we know: the first one is the answer.

CREATE OR REPLACE TABLE examined (label VARCHAR(120), rows_read BIGINT);

DELIMITER //
CREATE OR REPLACE PROCEDURE count_rows_read(IN p_label VARCHAR(120), IN p_sql TEXT)
BEGIN
  DECLARE before_run BIGINT;
  -- Handler_read_next counts the index entries a statement steps over after the first.
  SELECT VARIABLE_VALUE INTO before_run FROM information_schema.SESSION_STATUS
   WHERE VARIABLE_NAME = 'HANDLER_READ_NEXT';
  SET @counted_sql = p_sql;
  PREPARE counted FROM @counted_sql;
  EXECUTE counted;
  DEALLOCATE PREPARE counted;
  INSERT INTO examined
  SELECT p_label, VARIABLE_VALUE - before_run + 1 FROM information_schema.SESSION_STATUS
   WHERE VARIABLE_NAME = 'HANDLER_READ_NEXT';
END //
DELIMITER ;

CALL count_rows_read('as of 2010', "SELECT len INTO @a FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00' WHERE page_id = 24960699");
CALL count_rows_read('as of 2014', "SELECT len INTO @a FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2014-06-01 00:00:00' WHERE page_id = 24960699");
CALL count_rows_read('as of 2018', "SELECT len INTO @a FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2018-06-01 00:00:00' WHERE page_id = 24960699");
CALL count_rows_read('as of 2022', "SELECT len INTO @a FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2022-06-01 00:00:00' WHERE page_id = 24960699");
CALL count_rows_read('as of 2026', "SELECT len INTO @a FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2026-06-01 00:00:00' WHERE page_id = 24960699");
CALL count_rows_read('as of 2010, ORDER BY row_end LIMIT 1', "SELECT len INTO @a FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00' WHERE page_id = 24960699 ORDER BY row_end LIMIT 1");
CALL count_rows_read('as of 2026, ORDER BY row_end LIMIT 1', "SELECT len INTO @a FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2026-06-01 00:00:00' WHERE page_id = 24960699 ORDER BY row_end LIMIT 1");

-- The MariaDB article has 1,007 versions. Rows read to return one of them:
SELECT label, rows_read FROM examined;

CALL measure('as of', 'MariaDB article with text, as of 2010',
  "SELECT LENGTH(content) INTO @a FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00' WHERE page_id = 24960699");
CALL measure('as of', 'as of 2018',
  "SELECT LENGTH(content) INTO @a FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2018-06-01 00:00:00' WHERE page_id = 24960699");
CALL measure('as of', 'as of 2026',
  "SELECT LENGTH(content) INTO @a FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2026-06-01 00:00:00' WHERE page_id = 24960699");
CALL measure('as of', 'as of 2010, ORDER BY row_end LIMIT 1',
  "SELECT LENGTH(content) INTO @a FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00' WHERE page_id = 24960699 ORDER BY row_end LIMIT 1");
CALL measure('as of', 'as of 2026, ORDER BY row_end LIMIT 1',
  "SELECT LENGTH(content) INTO @a FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2026-06-01 00:00:00' WHERE page_id = 24960699 ORDER BY row_end LIMIT 1");
CALL measure('as of', 'the current row, no FOR SYSTEM_TIME',
  "SELECT LENGTH(content) INTO @a FROM wiki_time_machine.article WHERE page_id = 24960699");
CALL report('as of');

-- The shortcut is only right if no two versions of an article overlap, which
-- sql/90_checks.sql verifies for this table. Here: for every article, at every one of
-- the 27 moments, the newest version that had started is the one AS OF returns.
INSERT INTO check_result (test, pass)
SELECT 'ORDER BY row_end LIMIT 1 returns the version AS OF returns, for every article at 27 moments',
       NOT EXISTS (
         SELECT 1 FROM probe AS m
           JOIN wiki_time_machine.article FOR SYSTEM_TIME ALL AS a
             ON a.row_start <= m.at_time AND m.at_time < a.row_end
          WHERE a.rev_id <> (SELECT b.rev_id FROM wiki_time_machine.article FOR SYSTEM_TIME ALL AS b
                              WHERE b.page_id = a.page_id AND b.row_end > m.at_time
                              ORDER BY b.row_end LIMIT 1));
INSERT INTO check_result (test, pass)
SELECT 'the shortcut reads one row where the plain lookup of 2010 reads hundreds',
       (SELECT rows_read FROM examined WHERE label = 'as of 2010, ORDER BY row_end LIMIT 1') = 1
   AND (SELECT rows_read FROM examined WHERE label = 'as of 2010') > 100;


-- ===========================================================================
-- Done
-- ===========================================================================
CALL finish_checks('growth');

SET @@session.system_versioning_insert_history = 0;
SET @@session.system_versioning_alter_history = ERROR;
-- The copies are large. Set @keep = 1 before running to look around in them afterwards.
DELIMITER //
BEGIN NOT ATOMIC
  IF COALESCE(@keep, 0) = 0 THEN
    DROP DATABASE wtm_growth;
  END IF;
END //
DELIMITER ;
