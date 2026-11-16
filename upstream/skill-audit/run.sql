-- upstream/skill-audit/run.sql: MariaDB's own briefing for AI coding agents on
-- system-versioned tables, run statement by statement against a real server.
--
--     python scripts/run_sql.py upstream/skill-audit/run.sql
--
-- The briefing is github.com/MariaDB/skills, mariadb-system-versioned-tables/SKILL.md,
-- as of commit f5016dc (4 June 2026); a copy is next to this file as SKILL.audited.md.
-- An agent that follows it writes what it says, so every example in it should run.
-- This script runs each one and tests each claim that can be tested on one server.
-- The findings and the corrected briefing we propose are in upstream/README.md.
--
-- Needs no data: it works in its own database, wtm_skill_audit, and drops it at the end.
-- It records what THIS server does. Four results are the same on every version from
-- 10.11 on and are checked at the end; the rest are printed for the reader.

DROP DATABASE IF EXISTS wtm_skill_audit;
CREATE DATABASE wtm_skill_audit CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE wtm_skill_audit;
SET time_zone = '+00:00';
source experiments/harness.sql

CREATE TABLE audit (
  id        INT AUTO_INCREMENT PRIMARY KEY,
  section   VARCHAR(40) NOT NULL,     -- the heading in SKILL.md
  the_skill VARCHAR(200) NOT NULL,    -- what it says or shows there
  on_this_server VARCHAR(300) NOT NULL,
  verdict   VARCHAR(20) NOT NULL      -- holds, fails as written, wrong, out of date, unneeded
);

SELECT VERSION() AS mariadb;


-- ---------------------------------------------------------------------------
-- "Creating a System-Versioned Table"
-- ---------------------------------------------------------------------------
CALL attempt("CREATE TABLE employees (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100) NOT NULL, department VARCHAR(50), salary DECIMAL(10,2)) WITH SYSTEM VERSIONING");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Creating', 'example: CREATE TABLE employees ... WITH SYSTEM VERSIONING', @attempt_message, IF(@attempt_error = 0, 'holds', 'fails as written');

-- "Every INSERT, UPDATE, and DELETE creates a history row."
INSERT INTO employees (name, department, salary) VALUES ('Ada', 'engineering', 100), ('Bob', 'operations', 90);
SET @after_insert = (SELECT COUNT(*) FROM employees FOR SYSTEM_TIME ALL) - (SELECT COUNT(*) FROM employees);
UPDATE employees SET salary = 110 WHERE name = 'Ada';
SET @after_update = (SELECT COUNT(*) FROM employees FOR SYSTEM_TIME ALL) - (SELECT COUNT(*) FROM employees);
DELETE FROM employees WHERE name = 'Bob';
SET @after_delete = (SELECT COUNT(*) FROM employees FOR SYSTEM_TIME ALL) - (SELECT COUNT(*) FROM employees);
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Creating', 'claim: "Every INSERT, UPDATE, and DELETE creates a history row."',
       CONCAT('history rows after 2 INSERTs: ', @after_insert, '; after 1 UPDATE: ', @after_update, '; after 1 DELETE: ', @after_delete),
       IF(@after_insert = 0, 'wrong', 'holds');

CREATE TABLE plain (id INT PRIMARY KEY, v INT);
CALL attempt("ALTER TABLE plain ADD SYSTEM VERSIONING");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Creating', 'example: ALTER TABLE ... ADD SYSTEM VERSIONING', @attempt_message, IF(@attempt_error = 0, 'holds', 'fails as written');
CALL attempt("ALTER TABLE plain DROP SYSTEM VERSIONING");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Creating', 'example: ALTER TABLE ... DROP SYSTEM VERSIONING', @attempt_message, IF(@attempt_error = 0, 'holds', 'fails as written');


-- ---------------------------------------------------------------------------
-- "Querying Historical Data"
-- ---------------------------------------------------------------------------
CALL attempt("SELECT COUNT(*) INTO @n FROM employees FOR SYSTEM_TIME AS OF '2026-01-01 00:00:00'");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Querying', "example: FOR SYSTEM_TIME AS OF '2026-01-01 00:00:00'", @attempt_message, IF(@attempt_error = 0, 'holds', 'fails as written');
CALL attempt("SELECT COUNT(*) INTO @n FROM employees FOR SYSTEM_TIME BETWEEN '2025-01-01' AND '2026-01-01'");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Querying', "example: FOR SYSTEM_TIME BETWEEN '2025-01-01' AND '2026-01-01'", @attempt_message, IF(@attempt_error = 0, 'holds', 'fails as written');
CALL attempt("SELECT COUNT(*) INTO @n FROM employees FOR SYSTEM_TIME FROM '2025-01-01' TO '2026-01-01'");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Querying', "example: FOR SYSTEM_TIME FROM '2025-01-01' TO '2026-01-01'", @attempt_message, IF(@attempt_error = 0, 'holds', 'fails as written');
CALL attempt("SELECT COUNT(*) INTO @n FROM employees FOR SYSTEM_TIME ALL");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Querying', 'example: FOR SYSTEM_TIME ALL', @attempt_message, IF(@attempt_error = 0, 'holds', 'fails as written');
CALL attempt("CREATE TABLE one_employee AS SELECT *, ROW_START, ROW_END FROM employees FOR SYSTEM_TIME ALL WHERE id = 1");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Querying', 'example: SELECT *, ROW_START, ROW_END FROM employees FOR SYSTEM_TIME ALL WHERE id = ...', @attempt_message, IF(@attempt_error = 0, 'holds', 'fails as written');
--   Not in the skill, and an easy slip from its examples: the same date with the
--   TIMESTAMP keyword in front needs a time.
CALL attempt("SELECT COUNT(*) INTO @n FROM employees FOR SYSTEM_TIME AS OF TIMESTAMP '2026-01-01'");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Querying', "(not in the skill) AS OF TIMESTAMP '2026-01-01', a date without a time",
       CONCAT('error ', @attempt_error, ': ', @attempt_message), 'worth adding';

CALL attempt("SET system_versioning_asof = '2026-01-01 00:00:00'");
SELECT COUNT(*) INTO @seen_then FROM employees;
SET system_versioning_asof = DEFAULT;
SELECT COUNT(*) INTO @seen_now FROM employees;
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Querying', 'example: SET system_versioning_asof = ...; SELECT; SET ... = DEFAULT',
       CONCAT(@attempt_message, '; rows seen as of 2026-01-01: ', @seen_then, ', after the reset: ', @seen_now),
       IF(@attempt_error = 0 AND @seen_then = 0 AND @seen_now = 1, 'holds', 'wrong');


-- ---------------------------------------------------------------------------
-- "Transaction-Precise History"
-- ---------------------------------------------------------------------------
CALL attempt("CREATE TABLE ledger (id INT, amount DECIMAL(10,2), trx_start BIGINT UNSIGNED GENERATED ALWAYS AS ROW START, trx_end BIGINT UNSIGNED GENERATED ALWAYS AS ROW END, PERIOD FOR SYSTEM_TIME(trx_start, trx_end)) WITH SYSTEM VERSIONING");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Transaction-precise', 'example: CREATE TABLE ledger (... BIGINT UNSIGNED ... AS ROW START ...)', @attempt_message, IF(@attempt_error = 0, 'holds', 'fails as written');
CALL attempt("ALTER TABLE ledger PARTITION BY SYSTEM_TIME (PARTITION p_hist HISTORY, PARTITION p_cur CURRENT)");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Transaction-precise', 'claim: not compatible with PARTITION BY SYSTEM_TIME',
       CONCAT('error ', @attempt_error, ': ', LEFT(@attempt_message, 110)), IF(@attempt_error <> 0, 'holds', 'wrong');


-- ---------------------------------------------------------------------------
-- "Column-Level Control"
-- ---------------------------------------------------------------------------
CALL attempt("CREATE TABLE products (id INT PRIMARY KEY, name VARCHAR(100), price DECIMAL(10,2), view_count INT WITHOUT SYSTEM VERSIONING) WITH SYSTEM VERSIONING");
INSERT INTO products VALUES (1, 'widget', 1.00, 0);
UPDATE products SET view_count = view_count + 1;
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Column-level', 'example: view_count INT WITHOUT SYSTEM VERSIONING ("not tracked")',
       CONCAT(@attempt_message, '; history rows after updating only view_count: ',
              (SELECT COUNT(*) FROM products FOR SYSTEM_TIME ALL) - (SELECT COUNT(*) FROM products)),
       IF(@attempt_error = 0, 'holds', 'fails as written');

--   The second example names a column `key`, which is a reserved word.
CALL attempt("CREATE TABLE config (key VARCHAR(50), value TEXT WITH SYSTEM VERSIONING)");
SET @config_error = @attempt_error;
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Column-level', 'example: CREATE TABLE config (key VARCHAR(50), value TEXT WITH SYSTEM VERSIONING)',
       CONCAT('error ', @attempt_error, ': ', LEFT(@attempt_message, 150)), IF(@attempt_error = 0, 'holds', 'fails as written');
CALL attempt("CREATE TABLE config (setting_name VARCHAR(50), value TEXT WITH SYSTEM VERSIONING)");
SET @config_fixed_error = @attempt_error;
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Column-level', 'our correction: the same with the column named setting_name', @attempt_message, IF(@attempt_error = 0, 'holds', 'fails as written');


-- ---------------------------------------------------------------------------
-- "Managing History Growth"
-- ---------------------------------------------------------------------------
CALL attempt("CREATE TABLE events (id INT, payload JSON) WITH SYSTEM VERSIONING PARTITION BY SYSTEM_TIME (PARTITION p_hist HISTORY, PARTITION p_cur CURRENT)");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'History growth', 'example: PARTITION BY SYSTEM_TIME (PARTITION p_hist HISTORY, PARTITION p_cur CURRENT)', @attempt_message, IF(@attempt_error = 0, 'holds', 'fails as written');

--   "Auto-rotate history by time interval": the example lists only a CURRENT partition.
CALL attempt("CREATE TABLE prices (symbol VARCHAR(10), price DECIMAL(10,4)) WITH SYSTEM VERSIONING PARTITION BY SYSTEM_TIME INTERVAL 1 MONTH AUTO (PARTITION p_cur CURRENT)");
SET @prices_error = @attempt_error;
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'History growth', 'example: PARTITION BY SYSTEM_TIME INTERVAL 1 MONTH AUTO (PARTITION p_cur CURRENT)',
       CONCAT('error ', @attempt_error, ': ', LEFT(@attempt_message, 150)), IF(@attempt_error = 0, 'holds', 'fails as written');
CALL attempt("CREATE TABLE prices (symbol VARCHAR(10), price DECIMAL(10,4)) WITH SYSTEM VERSIONING PARTITION BY SYSTEM_TIME INTERVAL 1 MONTH AUTO");
SET @prices_fixed_error = @attempt_error;
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'History growth', 'our correction: the same without the partition list', @attempt_message, IF(@attempt_error = 0, 'holds', 'fails as written');

CALL attempt("DELETE HISTORY FROM employees BEFORE SYSTEM_TIME '2024-01-01'");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'History growth', "example: DELETE HISTORY FROM employees BEFORE SYSTEM_TIME '2024-01-01'", @attempt_message, IF(@attempt_error = 0, 'holds', 'fails as written');

--   "Delete all history (requires DROP SYSTEM VERSIONING + re-add, or partition drop):
--    ALTER TABLE employees DROP PARTITION p_hist;"
--   employees is not partitioned; p_hist is the history partition of the skill's events table.
INSERT INTO events VALUES (1, '{}');
UPDATE events SET payload = '{"edited": true}';
CALL attempt("ALTER TABLE employees DROP PARTITION p_hist");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'History growth', 'example: ALTER TABLE employees DROP PARTITION p_hist',
       CONCAT('error ', @attempt_error, ': ', LEFT(@attempt_message, 150)), IF(@attempt_error = 0, 'holds', 'fails as written');
CALL attempt("ALTER TABLE events DROP PARTITION p_hist");
SET @drop_only_error = @attempt_error;
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'History growth', 'the same on the table that has p_hist (events): dropping its only history partition',
       CONCAT('error ', @attempt_error, ': ', LEFT(@attempt_message, 150)), IF(@attempt_error = 0, 'holds', 'fails as written');
SET @history_before = (SELECT COUNT(*) FROM events FOR SYSTEM_TIME ALL) - (SELECT COUNT(*) FROM events);
CALL attempt("DELETE HISTORY FROM events");
SET @history_after = (SELECT COUNT(*) FROM events FOR SYSTEM_TIME ALL) - (SELECT COUNT(*) FROM events);
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'History growth', 'claim: deleting all history "requires DROP SYSTEM VERSIONING + re-add, or partition drop"',
       CONCAT('DELETE HISTORY FROM events: ', @attempt_message, '; history rows before: ', @history_before, ', after: ', @history_after),
       IF(@attempt_error = 0 AND @history_before > 0 AND @history_after = 0, 'wrong', 'holds');

CALL attempt("TRUNCATE TABLE employees");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'History growth', 'claim: TRUNCATE is not allowed (error 4137)',
       CONCAT('error ', @attempt_error, ': ', @attempt_message), IF(@attempt_error = 4137, 'holds', 'wrong');


-- ---------------------------------------------------------------------------
-- "ALTER TABLE on Versioned Tables"
-- ---------------------------------------------------------------------------
CALL attempt("ALTER TABLE employees ADD COLUMN manager_id INT");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'ALTER TABLE', 'claim: by default ALTER TABLE on a versioned table raises an error',
       CONCAT('error ', @attempt_error, ': ', LEFT(@attempt_message, 120)), IF(@attempt_error <> 0, 'holds', 'wrong');
SET system_versioning_alter_history = KEEP;
CALL attempt("ALTER TABLE employees ADD COLUMN manager_id INT");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'ALTER TABLE', 'example: SET system_versioning_alter_history = KEEP; ALTER ... ADD COLUMN manager_id INT',
       CONCAT(@attempt_message, '; manager_id in the history rows: ',
              (SELECT IF(COUNT(manager_id) = 0, 'NULL', 'not NULL') FROM employees FOR SYSTEM_TIME ALL)),
       IF(@attempt_error = 0, 'holds', 'fails as written');
--   What the skill leaves out: with a DEFAULT, the old versions show the default.
CALL attempt("ALTER TABLE employees ADD COLUMN grade INT NOT NULL DEFAULT 7");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'ALTER TABLE', '(not in the skill) ADD COLUMN ... NOT NULL DEFAULT 7: what old versions show',
       CONCAT('grade in the history rows: ', (SELECT GROUP_CONCAT(DISTINCT grade) FROM employees FOR SYSTEM_TIME ALL)), 'worth adding';
--   "Convert hidden ROW_START/ROW_END to explicit columns (11.7+)."
CALL attempt("ALTER TABLE employees ADD COLUMN rs TIMESTAMP(6) GENERATED ALWAYS AS ROW START, ADD COLUMN re TIMESTAMP(6) GENERATED ALWAYS AS ROW END, ADD PERIOD FOR SYSTEM_TIME (rs, re)");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'ALTER TABLE', 'claim: hidden period columns can be made explicit from 11.7 on',
       IF(@attempt_error = 0, 'accepted', CONCAT('error ', @attempt_error, ': ', LEFT(@attempt_message, 100))),
       IF((@attempt_error = 0) = (VERSION() NOT REGEXP '^(10\\.|11\\.[0-6]\\.)'), 'holds', 'wrong');
SET system_versioning_alter_history = ERROR;


-- ---------------------------------------------------------------------------
-- "Key Gotchas"
-- ---------------------------------------------------------------------------
--   "DELETE HISTORY with future timestamps ... can accidentally delete active rows
--    (MDEV-25468)". That bug was fixed in 10.3.29, 10.4.19 and 10.5.10.
CREATE TABLE future (id INT PRIMARY KEY, v INT) WITH SYSTEM VERSIONING;
INSERT INTO future VALUES (1, 1), (2, 2);
UPDATE future SET v = 3 WHERE id = 1;
CALL attempt("DELETE HISTORY FROM future BEFORE SYSTEM_TIME '2200-01-01 00:00:00'");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Key gotchas', 'claim: DELETE HISTORY with a future timestamp can delete active rows (MDEV-25468)',
       CONCAT("BEFORE SYSTEM_TIME '2200-01-01': ", @attempt_message, '; current rows left: ', (SELECT COUNT(*) FROM future),
              ' of 2, history rows left: ', (SELECT COUNT(*) FROM future FOR SYSTEM_TIME ALL) - (SELECT COUNT(*) FROM future)),
       IF((SELECT COUNT(*) FROM future) = 2, 'out of date', 'holds');

--   "SYSTEM as a column name: causes parser errors in ALTER TABLE statements."
--   True of the short forms, where the parser expects VERSIONING after SYSTEM.
CALL attempt("ALTER TABLE plain ADD system INT");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Key gotchas', 'claim: SYSTEM as a column name causes parser errors in ALTER TABLE (tried: ADD system INT)',
       IF(@attempt_error = 0, 'accepted', CONCAT('error ', @attempt_error, ': ', LEFT(@attempt_message, 100))),
       IF(@attempt_error <> 0, 'holds', 'wrong');
CALL attempt("ALTER TABLE plain ADD `system` INT");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Key gotchas', 'claim: ... use backticks (tried: ADD `system` INT)', @attempt_message, IF(@attempt_error = 0, 'holds', 'wrong');
ALTER TABLE plain DROP COLUMN `system`;
CALL attempt("ALTER TABLE plain ADD COLUMN system INT");
INSERT INTO audit (section, the_skill, on_this_server, verdict)
SELECT 'Key gotchas', '(not in the skill) the same with the COLUMN keyword and no backticks: ADD COLUMN system INT',
       @attempt_message, 'worth adding';


-- ---------------------------------------------------------------------------
-- What the audit found
-- ---------------------------------------------------------------------------
SELECT section, the_skill, on_this_server, verdict FROM audit ORDER BY id;
SELECT verdict, COUNT(*) AS items FROM audit GROUP BY verdict ORDER BY items DESC;

-- The four corrections we propose rest on these, on every version from 10.11 on.
INSERT INTO check_result (test, pass)
SELECT 'an INSERT creates no history row', @after_insert = 0 AND @after_update = 1 AND @after_delete = 2;
INSERT INTO check_result (test, pass)
SELECT 'the config example fails with a syntax error (1064), and runs once the column is not called key',
       @config_error = 1064 AND @config_fixed_error = 0;
INSERT INTO check_result (test, pass)
SELECT 'the AUTO example with only a CURRENT partition fails (4128), and runs without the partition list',
       @prices_error = 4128 AND @prices_fixed_error = 0;
INSERT INTO check_result (test, pass)
SELECT 'the only history partition cannot be dropped (4128), and DELETE HISTORY removes all history',
       @drop_only_error = 4128 AND @history_before > 0 AND @history_after = 0;
INSERT INTO check_result (test, pass)
SELECT 'DELETE HISTORY before a far-future time leaves the current rows alone',
       (SELECT COUNT(*) FROM future) = 2;

CALL finish_checks('skill-audit');
DROP DATABASE wtm_skill_audit;
