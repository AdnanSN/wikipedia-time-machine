-- experiments/before-after/run.sql: the same history kept three ways, and the places
-- where system versioning stops being the right answer (milestone M5). The write-up is
-- docs/before-and-after.md.
--
--     python scripts/run_sql.py experiments/before-after/run.sql
--
-- Needs the database built by run_all.sql. Works in its own database, wtm_before_after,
-- which it drops at the end; it only reads wiki_time_machine. Run it as an account
-- that may create users (root): part 5c creates a locked account, wtm_ordinary, to
-- show what an account with few rights can do, and drops it again.
--
--   the application's way   a revision table that application code must fill (MediaWiki)
--   the trigger way         a plain table, a history table and triggers (MySQL, PostgreSQL)
--   the server's way        WITH SYSTEM VERSIONING (MariaDB)
--
-- Parts: 1 what each needs, 2 the same question three ways, 3 what an edit costs,
--        4 what triggers miss, 5 where system versioning stops being the right answer.

DROP DATABASE IF EXISTS wtm_before_after;
CREATE DATABASE wtm_before_after CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE wtm_before_after;
SET time_zone = '+00:00';
source experiments/harness.sql

SELECT VERSION() AS mariadb, @@version_compile_os AS os,
       ROUND(@@innodb_buffer_pool_size / 1048576) AS buffer_pool_mb,
       @@innodb_flush_log_at_trx_commit AS flush_log_at_commit, @runs AS timed_runs_per_statement;


-- ===========================================================================
-- 1. What each way needs
-- ===========================================================================

-- The application's way is already in the main database: wiki_time_machine.page and
-- wiki_time_machine.revision (sql/01_schema.sql). No object below belongs to it; its
-- cost is in the application, which must write the revision row on every edit.

-- The trigger way: the current rows, a second table for the old ones, and two triggers
-- that copy a row across before it changes or disappears.
CREATE TABLE trig_article (
  page_id    INT UNSIGNED NOT NULL PRIMARY KEY,
  title      VARCHAR(255) NOT NULL,
  rev_id     INT UNSIGNED NOT NULL,
  editor     VARCHAR(255) NULL,
  summary    TEXT NULL,
  minor_edit BOOLEAN NOT NULL,
  len        INT UNSIGNED NULL,
  sha1       CHAR(40) NULL,
  tags       VARCHAR(1024) NULL,
  content    MEDIUMTEXT NULL,
  valid_from TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
);

CREATE TABLE trig_history (
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
  valid_from TIMESTAMP(6) NOT NULL,
  valid_to   TIMESTAMP(6) NOT NULL,
  PRIMARY KEY (page_id, valid_to)
);

DELIMITER //
CREATE TRIGGER trig_article_before_update BEFORE UPDATE ON trig_article FOR EACH ROW
BEGIN
  INSERT INTO trig_history (page_id, title, rev_id, editor, summary, minor_edit, len, sha1, tags,
                            content, valid_from, valid_to)
  VALUES (OLD.page_id, OLD.title, OLD.rev_id, OLD.editor, OLD.summary, OLD.minor_edit, OLD.len,
          OLD.sha1, OLD.tags, OLD.content, OLD.valid_from, NOW(6));
  SET NEW.valid_from = NOW(6);
END //
CREATE TRIGGER trig_article_before_delete BEFORE DELETE ON trig_article FOR EACH ROW
BEGIN
  INSERT INTO trig_history (page_id, title, rev_id, editor, summary, minor_edit, len, sha1, tags,
                            content, valid_from, valid_to)
  VALUES (OLD.page_id, OLD.title, OLD.rev_id, OLD.editor, OLD.summary, OLD.minor_edit, OLD.len,
          OLD.sha1, OLD.tags, OLD.content, OLD.valid_from, NOW(6));
END //
DELIMITER ;

-- The server's way: the table of the project. Its definition ends in three words.
CREATE TABLE sv_article LIKE wiki_time_machine.article;

-- What there is to write and to keep in step with every later change of the columns.
SELECT 'application (revision table)' AS way, 2 AS tables, 0 AS triggers, 0 AS characters_of_trigger_code,
       'every statement that edits must also insert a revision' AS kept_complete_by
UNION ALL
SELECT 'triggers',
       (SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'wtm_before_after' AND TABLE_NAME LIKE 'trig\_%'),
       (SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = 'wtm_before_after'),
       (SELECT SUM(CHAR_LENGTH(ACTION_STATEMENT)) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = 'wtm_before_after'),
       'two triggers, rewritten whenever a column is added'
UNION ALL
SELECT 'system versioning', 1, 0, 0, 'the server';

-- Fill all three with the same real history. For the trigger way and the application's
-- way this is an ordinary INSERT: their history is ordinary rows with ordinary date
-- columns. For the system-versioned table it needs system_versioning_insert_history.
-- (Importing dated history is the one thing the older designs make easier.)
INSERT INTO trig_history (page_id, title, rev_id, editor, summary, minor_edit, len, sha1, tags,
                          content, valid_from, valid_to)
SELECT page_id, title, rev_id, editor, summary, minor_edit, len, sha1, tags, content, row_start, row_end
FROM wiki_time_machine.article FOR SYSTEM_TIME ALL
WHERE row_end <= CURRENT_TIMESTAMP(6);
INSERT INTO trig_article (page_id, title, rev_id, editor, summary, minor_edit, len, sha1, tags, content, valid_from)
SELECT page_id, title, rev_id, editor, summary, minor_edit, len, sha1, tags, content, row_start
FROM wiki_time_machine.article;

SET @@session.system_versioning_insert_history = 1;
INSERT INTO sv_article SELECT * FROM wiki_time_machine.article FOR SYSTEM_TIME ALL;
SET @@session.system_versioning_insert_history = 0;

ANALYZE TABLE trig_article, trig_history, sv_article;
SELECT 'application: page + revision' AS way, ROUND(SUM(DATA_LENGTH + INDEX_LENGTH) / 1048576, 1) AS mb_on_disk
FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'wiki_time_machine' AND TABLE_NAME IN ('page', 'revision')
UNION ALL
SELECT 'triggers: trig_article + trig_history', ROUND(SUM(DATA_LENGTH + INDEX_LENGTH) / 1048576, 1)
FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'wtm_before_after' AND TABLE_NAME LIKE 'trig\_%'
UNION ALL
SELECT 'system versioning: sv_article', ROUND(SUM(DATA_LENGTH + INDEX_LENGTH) / 1048576, 1)
FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'wtm_before_after' AND TABLE_NAME = 'sv_article';


-- ===========================================================================
-- 2. The same question, three ways
-- ===========================================================================
-- "The MariaDB article as it stood on 1 June 2010."

-- The application's way: sort the article's revisions, take the newest before the moment.
SELECT 'application' AS way, r.rev_id, r.rev_timestamp AS saved_at
FROM wiki_time_machine.page AS p
JOIN wiki_time_machine.revision AS r ON r.rev_page = p.page_id
WHERE p.page_title = 'MariaDB' AND r.rev_timestamp <= '2010-06-01 00:00:00'
ORDER BY r.rev_timestamp DESC, r.rev_id DESC
LIMIT 1;

-- The trigger way: the answer may be in either table, so ask both.
SELECT 'triggers' AS way, rev_id, valid_from AS saved_at
FROM (SELECT title, rev_id, valid_from, NULL AS valid_to FROM trig_article
      UNION ALL
      SELECT title, rev_id, valid_from, valid_to FROM trig_history) AS both_tables
WHERE title = 'MariaDB' AND valid_from <= '2010-06-01 00:00:00'
  AND (valid_to > '2010-06-01 00:00:00' OR valid_to IS NULL);

-- The server's way.
SELECT 'system versioning' AS way, rev_id, row_start AS saved_at
FROM sv_article FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'
WHERE title = 'MariaDB';

-- "Every article as it stood on that day" is where the three part ways: one clause for
-- the server, a UNION for the triggers, a window function for the revision table.
CREATE OR REPLACE TABLE probe (at_time DATETIME(6) PRIMARY KEY);
INSERT INTO probe SELECT TIMESTAMP(CONCAT(seq, '-01-01 00:30:00')) FROM seq_2001_to_2027;

INSERT INTO check_result (test, pass)
SELECT 'the trigger tables and the versioned table give the same answer for every article at 27 moments',
       NOT EXISTS (
         SELECT 1 FROM probe AS m
           JOIN sv_article FOR SYSTEM_TIME ALL AS s ON s.row_start <= m.at_time AND m.at_time < s.row_end
           LEFT JOIN (SELECT page_id, rev_id, valid_from, TIMESTAMP '2037-01-01 00:00:00' AS valid_to FROM trig_article
                      UNION ALL
                      SELECT page_id, rev_id, valid_from, valid_to FROM trig_history) AS t
             ON t.page_id = s.page_id AND t.valid_from <= m.at_time AND m.at_time < t.valid_to
          WHERE t.rev_id IS NULL OR t.rev_id <> s.rev_id);

CALL measure('ask', 'application: one article with text as of 2010',
  "SELECT LENGTH(r.content) INTO @a FROM wiki_time_machine.revision AS r WHERE r.rev_page = 24960699 AND r.rev_timestamp <= '2010-06-01 00:00:00' ORDER BY r.rev_timestamp DESC, r.rev_id DESC LIMIT 1");
CALL measure('ask', 'triggers: one article with text as of 2010',
  "SELECT LENGTH(content) INTO @a FROM (SELECT page_id, content, valid_from, NULL AS valid_to FROM trig_article UNION ALL SELECT page_id, content, valid_from, valid_to FROM trig_history) AS both_tables WHERE page_id = 24960699 AND valid_from <= '2010-06-01 00:00:00' AND (valid_to > '2010-06-01 00:00:00' OR valid_to IS NULL)");
CALL measure('ask', 'system versioning: one article with text as of 2010',
  "SELECT LENGTH(content) INTO @a FROM sv_article FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00' WHERE page_id = 24960699 ORDER BY row_end LIMIT 1");
CALL measure('ask', 'application: every article as of 2010, no text',
  "SELECT COUNT(*), SUM(rev_len) INTO @a, @b FROM (SELECT rev_len, ROW_NUMBER() OVER (PARTITION BY rev_page ORDER BY rev_timestamp DESC, rev_id DESC) AS newest FROM wiki_time_machine.revision WHERE rev_timestamp <= '2010-06-01 00:00:00') AS ranked WHERE newest = 1");
CALL measure('ask', 'triggers: every article as of 2010, no text',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM (SELECT len, valid_from, NULL AS valid_to FROM trig_article UNION ALL SELECT len, valid_from, valid_to FROM trig_history) AS both_tables WHERE valid_from <= '2010-06-01 00:00:00' AND (valid_to > '2010-06-01 00:00:00' OR valid_to IS NULL)");
CALL measure('ask', 'system versioning: every article as of 2010, no text',
  "SELECT COUNT(*), SUM(len) INTO @a, @b FROM sv_article FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'");
CALL report('ask');


-- ===========================================================================
-- 3. What an edit costs
-- ===========================================================================
-- The last 200 edits of the MariaDB article (about 75 kB of text each), made again in
-- each design, one transaction per edit as on a live site. A fourth table keeps no
-- history at all: the difference to it is what remembering costs.

CREATE TABLE no_history LIKE trig_article;
INSERT INTO no_history SELECT * FROM trig_article;

CREATE TABLE app_page LIKE wiki_time_machine.page;
CREATE TABLE app_revision LIKE wiki_time_machine.revision;
INSERT INTO app_page SELECT * FROM wiki_time_machine.page;

CREATE TABLE edit_list (step INT AUTO_INCREMENT PRIMARY KEY, rev_id INT UNSIGNED NOT NULL);
INSERT INTO edit_list (rev_id)
SELECT rev_id FROM (SELECT rev_id, rev_timestamp FROM wiki_time_machine.revision
                    WHERE rev_page = 24960699 ORDER BY rev_timestamp DESC, rev_id DESC LIMIT 200) AS latest
ORDER BY rev_timestamp, rev_id;

DELIMITER //
CREATE OR REPLACE PROCEDURE edit_in(IN p_way VARCHAR(20))
BEGIN
  DECLARE done BOOLEAN DEFAULT FALSE;
  DECLARE v_rev INT UNSIGNED;
  DECLARE edits CURSOR FOR SELECT rev_id FROM edit_list ORDER BY step;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;
  OPEN edits;
  each_edit: LOOP
    FETCH edits INTO v_rev;
    IF done THEN LEAVE each_edit; END IF;
    CASE p_way
      WHEN 'none' THEN
        UPDATE no_history AS a JOIN wiki_time_machine.revision AS r ON r.rev_id = v_rev
           SET a.rev_id = r.rev_id, a.editor = r.rev_actor, a.summary = r.rev_comment, a.len = r.rev_len,
               a.sha1 = r.rev_sha1, a.content = r.content
         WHERE a.page_id = 24960699;
      WHEN 'triggers' THEN
        UPDATE trig_article AS a JOIN wiki_time_machine.revision AS r ON r.rev_id = v_rev
           SET a.rev_id = r.rev_id, a.editor = r.rev_actor, a.summary = r.rev_comment, a.len = r.rev_len,
               a.sha1 = r.rev_sha1, a.content = r.content
         WHERE a.page_id = 24960699;
      WHEN 'versioning' THEN
        UPDATE sv_article AS a JOIN wiki_time_machine.revision AS r ON r.rev_id = v_rev
           SET a.rev_id = r.rev_id, a.editor = r.rev_actor, a.summary = r.rev_comment, a.len = r.rev_len,
               a.sha1 = r.rev_sha1, a.content = r.content
         WHERE a.page_id = 24960699;
      ELSE
        -- The application's way: two statements that must succeed or fail together.
        START TRANSACTION;
        INSERT INTO app_revision SELECT * FROM wiki_time_machine.revision WHERE rev_id = v_rev;
        UPDATE app_page SET page_latest = v_rev WHERE page_id = 24960699;
        COMMIT;
    END CASE;
  END LOOP;
  CLOSE edits;
END //

CREATE OR REPLACE PROCEDURE time_edits()
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE started DATETIME(6);
  WHILE i <= LEAST(@runs, 5) DO
    SET started = SYSDATE(6); CALL edit_in('none');
    INSERT INTO timing (topic, label, run, ms) VALUES ('edit', 'no history kept: 200 edits', i, TIMESTAMPDIFF(MICROSECOND, started, SYSDATE(6)) / 1000);
    SET started = SYSDATE(6); CALL edit_in('application');
    INSERT INTO timing (topic, label, run, ms) VALUES ('edit', 'application writes a revision row: 200 edits', i, TIMESTAMPDIFF(MICROSECOND, started, SYSDATE(6)) / 1000);
    DELETE FROM app_revision;
    SET started = SYSDATE(6); CALL edit_in('triggers');
    INSERT INTO timing (topic, label, run, ms) VALUES ('edit', 'triggers copy the old row: 200 edits', i, TIMESTAMPDIFF(MICROSECOND, started, SYSDATE(6)) / 1000);
    SET started = SYSDATE(6); CALL edit_in('versioning');
    INSERT INTO timing (topic, label, run, ms) VALUES ('edit', 'system versioning: 200 edits', i, TIMESTAMPDIFF(MICROSECOND, started, SYSDATE(6)) / 1000);
    SET i = i + 1;
  END WHILE;
END //
DELIMITER ;

SELECT COUNT(*) AS edits, ROUND(AVG(rev_len)) AS avg_bytes_of_text_per_edit
FROM edit_list JOIN wiki_time_machine.revision USING (rev_id);

SET @versions_before = (SELECT COUNT(*) FROM sv_article FOR SYSTEM_TIME ALL);
SET @history_before = (SELECT COUNT(*) FROM trig_history);
CALL time_edits();
CALL report('edit');

INSERT INTO check_result (test, pass)
SELECT 'every timed edit left one more version, in the versioned table and in the trigger history',
       (SELECT COUNT(*) FROM sv_article FOR SYSTEM_TIME ALL) - @versions_before = 200 * LEAST(@runs, 5)
   AND (SELECT COUNT(*) FROM trig_history) - @history_before = 200 * LEAST(@runs, 5);


-- ===========================================================================
-- 4. What triggers miss
-- ===========================================================================
-- A small table of notes on articles, kept twice: once with a history trigger, once
-- system-versioned. Each test does the same thing to both and counts what was recorded.

CREATE TABLE topic (topic_id INT PRIMARY KEY, name VARCHAR(40));
CREATE TABLE note_trig (note_id INT PRIMARY KEY, topic_id INT NULL, body VARCHAR(100),
  FOREIGN KEY (topic_id) REFERENCES topic (topic_id) ON DELETE CASCADE);
CREATE TABLE note_trig_history (note_id INT, topic_id INT, body VARCHAR(100), ended TIMESTAMP(6));
CREATE TRIGGER note_trig_before_delete BEFORE DELETE ON note_trig FOR EACH ROW
  INSERT INTO note_trig_history VALUES (OLD.note_id, OLD.topic_id, OLD.body, NOW(6));
CREATE TRIGGER note_trig_before_update BEFORE UPDATE ON note_trig FOR EACH ROW
  INSERT INTO note_trig_history VALUES (OLD.note_id, OLD.topic_id, OLD.body, NOW(6));
CREATE TABLE note_sv (note_id INT PRIMARY KEY, topic_id INT NULL, body VARCHAR(100),
  FOREIGN KEY (topic_id) REFERENCES topic (topic_id) ON DELETE CASCADE) WITH SYSTEM VERSIONING;

-- 4a. A cascading foreign key. Deleting the topic deletes its notes in both tables, but
--     a cascade does not run triggers.
INSERT INTO topic VALUES (1, 'temporal tables');
INSERT INTO note_trig VALUES (10, 1, 'first note'), (11, 1, 'second note');
INSERT INTO note_sv VALUES (10, 1, 'first note'), (11, 1, 'second note');
DELETE FROM topic WHERE topic_id = 1;
INSERT INTO finding (topic, what, observed)
SELECT 'miss', 'cascading delete of 2 notes: recorded by the trigger / kept by the server',
       CONCAT((SELECT COUNT(*) FROM note_trig_history), ' / ',
              (SELECT COUNT(*) FROM note_sv FOR SYSTEM_TIME ALL) - (SELECT COUNT(*) FROM note_sv));

-- 4b. TRUNCATE TABLE. It empties a table without running DELETE triggers; a
--     system-versioned table refuses it.
INSERT INTO note_trig VALUES (20, NULL, 'will be truncated');
INSERT INTO note_sv VALUES (20, NULL, 'will be truncated');
DELETE FROM note_trig_history;
CALL attempt('TRUNCATE TABLE note_trig');
INSERT INTO finding (topic, what, observed)
SELECT 'miss', 'TRUNCATE on the trigger table: rows left / rows recorded',
       CONCAT(@attempt_message, ': ', (SELECT COUNT(*) FROM note_trig), ' / ', (SELECT COUNT(*) FROM note_trig_history));
CALL attempt('TRUNCATE TABLE note_sv');
INSERT INTO finding (topic, what, observed)
SELECT 'miss', 'TRUNCATE on the versioned table', CONCAT('error ', @attempt_error, ': ', @attempt_message);

-- 4c. The history itself. A trigger's history table is an ordinary table: whoever may
--     write to it may rewrite the past. The server's history rows cannot be addressed
--     by UPDATE or DELETE at all.
INSERT INTO note_trig VALUES (30, NULL, 'original');
INSERT INTO note_sv VALUES (30, NULL, 'original');
UPDATE note_trig SET body = 'edited' WHERE note_id = 30;
UPDATE note_sv SET body = 'edited' WHERE note_id = 30;
CALL attempt("UPDATE note_trig_history SET body = 'it never said that' WHERE note_id = 30");
INSERT INTO finding (topic, what, observed)
SELECT 'miss', 'rewriting a row of the trigger history', CONCAT(@attempt_message, ': it now reads "',
       (SELECT body FROM note_trig_history WHERE note_id = 30), '"');
CALL attempt("UPDATE note_sv SET body = 'it never said that' WHERE note_id = 30 AND body = 'original'");
INSERT INTO finding (topic, what, observed)
SELECT 'miss', 'the same UPDATE aimed at a history row of the versioned table',
       CONCAT(@attempt_message, ', rows changed: ', ROW_COUNT(), '; the history still reads "',
              (SELECT body FROM note_sv FOR SYSTEM_TIME ALL WHERE note_id = 30 ORDER BY ROW_START LIMIT 1), '"');
CALL attempt("UPDATE note_sv FOR SYSTEM_TIME ALL SET body = 'it never said that' WHERE note_id = 30");
INSERT INTO finding (topic, what, observed)
SELECT 'miss', 'UPDATE ... FOR SYSTEM_TIME ALL on the versioned table', CONCAT('error ', @attempt_error, ': ', @attempt_message);
CALL attempt("DELETE HISTORY FROM note_sv WHERE note_id = 30");
INSERT INTO finding (topic, what, observed)
SELECT 'miss', 'DELETE HISTORY ... WHERE (one row''s history)', CONCAT('error ', @attempt_error, ': ', LEFT(@attempt_message, 60));

-- 4d. Dropping the trigger. Afterwards edits go unrecorded, and nothing says so.
DROP TRIGGER note_trig_before_update;
SET @recorded = (SELECT COUNT(*) FROM note_trig_history);
UPDATE note_trig SET body = 'edited again' WHERE note_id = 30;
INSERT INTO finding (topic, what, observed)
SELECT 'miss', 'an edit after DROP TRIGGER: new history rows', (SELECT COUNT(*) FROM note_trig_history) - @recorded;

SELECT what, observed FROM finding WHERE topic = 'miss' ORDER BY id;

INSERT INTO check_result (test, pass)
SELECT 'a cascading delete is missed by the trigger and kept by the versioned table',
       (SELECT observed FROM finding WHERE what LIKE 'cascading delete%') = '0 / 2';
INSERT INTO check_result (test, pass)
SELECT 'a system-versioned table refuses TRUNCATE (error 4137)',
       (SELECT observed FROM finding WHERE what = 'TRUNCATE on the versioned table') LIKE 'error 4137%';


-- ===========================================================================
-- 5. Where system versioning stops being the right answer
-- ===========================================================================

-- 5a. Removing one version. Wikipedia's administrators hide single revisions (libel,
--     personal data); the GDPR asks the same of any system that stores personal data.
--     The server offers DELETE HISTORY for everything before a moment, or everything;
--     there is no WHERE (4c above; requested as MDEV-39738). What can be done instead:
--     keep the sensitive column out of versioning, and keep a versioned flag beside it.
CREATE TABLE redactable (
  rev_id  INT UNSIGNED NOT NULL PRIMARY KEY,
  hidden  BOOLEAN NOT NULL DEFAULT FALSE,
  content MEDIUMTEXT NULL WITHOUT SYSTEM VERSIONING
) WITH SYSTEM VERSIONING;
INSERT INTO redactable (rev_id, content) VALUES (1, 'a libellous sentence'), (2, 'another libellous sentence');

--     In one statement it does not work: the flag is versioned, so the server writes a
--     history row, and that row is a copy of the whole old row, text included.
UPDATE redactable SET hidden = TRUE, content = NULL WHERE rev_id = 1;
INSERT INTO finding (topic, what, observed)
SELECT 'limit', 'redaction in ONE statement: is the old text still in the history?',
       IF(COUNT(*) > 0, 'yes, FOR SYSTEM_TIME ALL still returns it', 'no')
FROM redactable FOR SYSTEM_TIME ALL WHERE rev_id = 1 AND content = 'a libellous sentence';

--     In two statements it does: first the text alone (an UPDATE of an unversioned
--     column makes no history row, so the text is simply gone), then the flag (whose
--     history row has nothing left to leak).
UPDATE redactable SET content = NULL WHERE rev_id = 2;
UPDATE redactable SET hidden = TRUE WHERE rev_id = 2;
INSERT INTO finding (topic, what, observed)
SELECT 'limit', 'redaction in TWO statements, text first: is the old text still in the history?',
       IF(COUNT(*) > 0, 'yes', 'no; and the history still shows when the flag was set')
FROM redactable FOR SYSTEM_TIME ALL WHERE rev_id = 2 AND content = 'another libellous sentence';

-- 5b. Who made the change. The server records when, never who (requested as MDEV-16858).
--     A column and a three-line trigger add it, and versioning then keeps it.
CREATE TABLE who (id INT PRIMARY KEY, body VARCHAR(100), changed_by VARCHAR(128) NOT NULL DEFAULT CURRENT_USER())
  WITH SYSTEM VERSIONING;
CREATE TRIGGER who_before_update BEFORE UPDATE ON who FOR EACH ROW SET NEW.changed_by = CURRENT_USER();
INSERT INTO who (id, body) VALUES (1, 'first');
UPDATE who SET body = 'second' WHERE id = 1;
INSERT INTO finding (topic, what, observed)
SELECT 'limit', 'who changed it: versions that carry an account name', CONCAT(COUNT(*), ' of ', COUNT(changed_by))
FROM who FOR SYSTEM_TIME ALL WHERE changed_by LIKE '%@%';

-- 5c. Who may rewrite the past. DELETE HISTORY needs a privilege of its own. Writing a
--     version that never existed, or erasing one, does not: the server takes the time
--     from the session, and with secure_timestamp = NO (the default) a session may set
--     both its clock and system_versioning_insert_history.
--     To show it without logging in as someone else, the statements below run inside a
--     procedure that executes with the rights of its definer, an account that may
--     SELECT, INSERT, UPDATE and DELETE in one table and nothing more. The account is
--     locked, so nobody can log in with it, and it is dropped again at the end.
CREATE TABLE guarded (id INT PRIMARY KEY, body VARCHAR(100),
  row_start TIMESTAMP(6) GENERATED ALWAYS AS ROW START, row_end TIMESTAMP(6) GENERATED ALWAYS AS ROW END,
  PERIOD FOR SYSTEM_TIME (row_start, row_end)) WITH SYSTEM VERSIONING;
INSERT INTO guarded (id, body) VALUES (2, 'what was really said');

CREATE OR REPLACE USER wtm_ordinary@localhost ACCOUNT LOCK;
GRANT SELECT, INSERT, UPDATE, DELETE ON wtm_before_after.guarded TO wtm_ordinary@localhost;
DELIMITER //
CREATE DEFINER = wtm_ordinary@localhost PROCEDURE as_ordinary_user(IN p_sql TEXT) SQL SECURITY DEFINER
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    GET DIAGNOSTICS CONDITION 1 @attempt_error = MYSQL_ERRNO, @attempt_message = MESSAGE_TEXT;
  END;
  SET @attempt_error = 0, @attempt_message = 'accepted';
  SET @ordinary_sql = p_sql;
  PREPARE ordinary FROM @ordinary_sql;
  EXECUTE ordinary;
  DEALLOCATE PREPARE ordinary;
END //
DELIMITER ;
GRANT EXECUTE ON PROCEDURE wtm_before_after.as_ordinary_user TO wtm_ordinary@localhost;

--     It really is the limited account: it may not even create a table.
CALL as_ordinary_user("CREATE TABLE not_allowed (id INT)");
INSERT INTO finding (topic, what, observed)
SELECT 'limit', 'ordinary account: CREATE TABLE', CONCAT('error ', @attempt_error, ': ', LEFT(@attempt_message, 60));
--     A version that never existed, dated 2001.
CALL as_ordinary_user("SET @@session.system_versioning_insert_history = 1");
CALL as_ordinary_user("INSERT INTO guarded (id, body, row_start, row_end) VALUES (1, 'a version that never existed', '2001-01-01 00:00:00', '2002-01-01 00:00:00')");
INSERT INTO finding (topic, what, observed)
SELECT 'limit', 'ordinary account: INSERT a history row dated 2001', @attempt_message;
--     An UPDATE with the session clock set to before the row's current version started
--     does not add a version: it erases the one it replaces (reported as MDEV-41003).
CALL as_ordinary_user("SET timestamp = UNIX_TIMESTAMP('2016-01-01 00:00:00')");
CALL as_ordinary_user("UPDATE guarded SET body = 'what someone wants on record' WHERE id = 2");
INSERT INTO finding (topic, what, observed)
SELECT 'limit', 'ordinary account: UPDATE with its clock set back to 2016', @attempt_message;
--     The one thing it may not do.
CALL as_ordinary_user("DELETE HISTORY FROM guarded");
INSERT INTO finding (topic, what, observed)
SELECT 'limit', 'ordinary account: DELETE HISTORY', CONCAT('error ', @attempt_error, ': ', LEFT(@attempt_message, 60));
SET timestamp = DEFAULT;
SET @@session.system_versioning_insert_history = 0;
INSERT INTO finding (topic, what, observed)
SELECT 'limit', 'the table''s history afterwards', GROUP_CONCAT(CONCAT(YEAR(row_start), ': ', body) ORDER BY row_start SEPARATOR ' | ')
FROM guarded FOR SYSTEM_TIME ALL;
DROP PROCEDURE as_ordinary_user;
DROP USER wtm_ordinary@localhost;

-- 5d. Changing the table. ALTER TABLE is refused until the session says KEEP, and then
--     the past is rewritten into the new shape: every old version shows the new
--     column's default, a value nobody ever stored at that time.
CREATE TABLE shape (id INT PRIMARY KEY, body VARCHAR(100)) WITH SYSTEM VERSIONING;
INSERT INTO shape VALUES (1, 'v1');
UPDATE shape SET body = 'v2';
CALL attempt("ALTER TABLE shape ADD COLUMN licence VARCHAR(20) NOT NULL DEFAULT 'CC BY-SA 4.0'");
INSERT INTO finding (topic, what, observed)
SELECT 'limit', 'ALTER TABLE on a versioned table, default settings', CONCAT('error ', @attempt_error, ': ', LEFT(@attempt_message, 70));
SET @@session.system_versioning_alter_history = KEEP;
ALTER TABLE shape ADD COLUMN licence VARCHAR(20) NOT NULL DEFAULT 'CC BY-SA 4.0';
SET @@session.system_versioning_alter_history = ERROR;
INSERT INTO finding (topic, what, observed)
SELECT 'limit', 'after ALTER ... KEEP: the licence the oldest version claims to have had', licence
FROM shape FOR SYSTEM_TIME ALL WHERE body = 'v1';

-- 5e. Searching the past. A FULLTEXT index answers only for current rows, so MATCH
--     cannot find a word that an article used to contain (confirmed as MDEV-36991);
--     LIKE can, by reading every version.
CREATE TABLE words (id INT PRIMARY KEY, body TEXT, FULLTEXT KEY body (body)) WITH SYSTEM VERSIONING;
INSERT INTO words VALUES (1, 'Jacobs University Bremen');
UPDATE words SET body = 'Constructor University' WHERE id = 1;
INSERT INTO finding (topic, what, observed)
SELECT 'limit', 'a word only the old version has: found by LIKE / found by MATCH',
       CONCAT((SELECT COUNT(*) FROM words FOR SYSTEM_TIME ALL WHERE body LIKE '%Jacobs%'), ' / ',
              (SELECT COUNT(*) FROM words FOR SYSTEM_TIME ALL WHERE MATCH(body) AGAINST ('Jacobs' IN BOOLEAN MODE)));

-- 5f. The session-wide time machine covers SELECT statements and nothing else. Under
--     system_versioning_asof the same query returns the past as a SELECT, and the
--     present inside SET @variable = (SELECT ...) or CREATE TABLE ... AS SELECT.
SET system_versioning_asof = '2005-01-01 00:00:00';
SELECT COUNT(*) INTO @as_a_select FROM wiki_time_machine.article;
SET @inside_set = (SELECT COUNT(*) FROM wiki_time_machine.article);
CREATE OR REPLACE TABLE copied AS SELECT page_id FROM wiki_time_machine.article;
SET system_versioning_asof = DEFAULT;
INSERT INTO finding (topic, what, observed)
SELECT 'limit', 'articles as of 2005: as a SELECT / inside SET @v = (SELECT ...) / copied by CREATE TABLE ... AS SELECT',
       CONCAT(@as_a_select, ' / ', @inside_set, ' / ', (SELECT COUNT(*) FROM copied));

-- 5g. The period columns are TIMESTAMPs: nothing before 1970 can be a system time.
CREATE TABLE old_times (id INT PRIMARY KEY, body VARCHAR(100),
  row_start TIMESTAMP(6) GENERATED ALWAYS AS ROW START, row_end TIMESTAMP(6) GENERATED ALWAYS AS ROW END,
  PERIOD FOR SYSTEM_TIME (row_start, row_end)) WITH SYSTEM VERSIONING;
SET @@session.system_versioning_insert_history = 1;
CALL attempt("INSERT INTO old_times (id, body, row_start, row_end) VALUES (1, 'Codd, 1969', '1969-08-19 00:00:00', '1970-06-01 00:00:00')");
SET @@session.system_versioning_insert_history = 0;
INSERT INTO finding (topic, what, observed)
SELECT 'limit', 'a history row that starts in 1969', CONCAT('error ', @attempt_error, ': ', LEFT(@attempt_message, 70));
INSERT INTO finding (topic, what, observed)
SELECT 'limit', 'the end of time for a current row on this server', MAX(row_end) FROM wiki_time_machine.article;

SELECT what, observed FROM finding WHERE topic = 'limit' ORDER BY id;

INSERT INTO check_result (test, pass)
SELECT 'redacting in two statements, text first, leaves no copy of the text in the history',
       (SELECT observed FROM finding WHERE what LIKE 'redaction in TWO statements%') LIKE 'no;%'
   AND NOT EXISTS (SELECT 1 FROM redactable FOR SYSTEM_TIME ALL WHERE rev_id = 2 AND content IS NOT NULL)
   AND (SELECT COUNT(*) FROM redactable FOR SYSTEM_TIME ALL WHERE rev_id = 2) = 2;
INSERT INTO check_result (test, pass)
SELECT 'a trigger on a versioned table records who changed each version',
       (SELECT observed FROM finding WHERE what LIKE 'who changed it%') = '2 of 2';
-- (What the ordinary account managed to write is recorded above, not insisted on: it is
-- the kind of thing a later version may rightly refuse.)
INSERT INTO check_result (test, pass)
SELECT 'the ordinary account is refused DELETE HISTORY (and CREATE TABLE, so it really is ordinary)',
       (SELECT observed FROM finding WHERE what = 'ordinary account: DELETE HISTORY') LIKE 'error 1142%'
   AND (SELECT observed FROM finding WHERE what = 'ordinary account: CREATE TABLE') LIKE 'error 1142%';


-- ===========================================================================
-- Done
-- ===========================================================================
CALL finish_checks('before-and-after');

DELIMITER //
BEGIN NOT ATOMIC
  IF COALESCE(@keep, 0) = 0 THEN
    DROP DATABASE wtm_before_after;
  END IF;
END //
DELIMITER ;
