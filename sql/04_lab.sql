-- 04_lab.sql: making history, instead of loading it.
--
-- `article` holds Wikipedia's past, written with the real save times by
-- 02_build_history.sql. This script shows the other half of system versioning: what
-- the server does by itself when rows change. It creates `lab_page`, a second
-- system-versioned table, edits one page in it step by step, and prints what the server
-- kept. The web page's "Lab" (app/lab.py) lets you do the same by hand.
--
-- Nothing below writes a history row. Every statement is an ordinary INSERT, UPDATE or
-- DELETE; the versions it leaves behind are the server's work.
--
-- The script recreates lab_page, so running it again resets the lab.

USE wiki_time_machine;
SET time_zone = '+00:00';

-- The short form of the syntax: no period columns are declared. The server still keeps
-- them, hidden, and a query can read them under the names ROW_START and ROW_END.
CREATE OR REPLACE TABLE lab_page (
  page_id INT UNSIGNED NOT NULL PRIMARY KEY,
  title   VARCHAR(255) NOT NULL,
  content MEDIUMTEXT NOT NULL,
  editor  VARCHAR(255) NOT NULL,
  summary VARCHAR(500) NOT NULL DEFAULT ''
) WITH SYSTEM VERSIONING;

-- Something to edit in the web page's lab: the five shortest articles, as they stand now.
INSERT INTO lab_page (page_id, title, content, editor, summary)
SELECT page_id, title, content, COALESCE(editor, 'name hidden'), 'copied from the article table'
FROM article
ORDER BY len, page_id
LIMIT 5;

-- From here on the clock is set by hand, one minute per step, so that the output is the
-- same on every run. SET timestamp changes the time the session sees, and with it the
-- time the server stamps on rows. (A server started with secure_timestamp = YES would
-- refuse this; see docs/before-and-after.md.)

-- 1. A new page. An INSERT makes a current row and no history.
SET timestamp = UNIX_TIMESTAMP('2026-11-01 12:00:00');
INSERT INTO lab_page (page_id, title, content, editor, summary)
VALUES (1, 'Lab notes', 'MariaDB keeps the history of this page.', 'Ada', 'started the page');

-- 2. An edit is an UPDATE. The server keeps the text it replaces.
SET timestamp = UNIX_TIMESTAMP('2026-11-01 12:01:00');
UPDATE lab_page
SET content = 'MariaDB keeps the history of this page. Nobody wrote code for that.',
    editor = 'Ada', summary = 'said how'
WHERE page_id = 1;

-- 3. An UPDATE that changes nothing still makes a version: the server records that the
--    statement touched a versioned column, not whether the value differs (MDEV-23446).
SET timestamp = UNIX_TIMESTAMP('2026-11-01 12:02:00');
UPDATE lab_page SET content = content WHERE page_id = 1;

-- 4. Vandalism ...
SET timestamp = UNIX_TIMESTAMP('2026-11-01 12:03:00');
UPDATE lab_page
SET content = 'MARIADB IS A KIND OF SEAL', editor = 'Mallory', summary = ''
WHERE page_id = 1;

--    ... and its repair. The table is joined to its own past: `old` is the row as it
--    stood at 12:02:30, `now` is the current row. Restoring is an ordinary edit, so it
--    becomes a version too, and the vandalism stays on record.
SET timestamp = UNIX_TIMESTAMP('2026-11-01 12:04:00');
UPDATE lab_page AS now
JOIN lab_page FOR SYSTEM_TIME AS OF TIMESTAMP '2026-11-01 12:02:30' AS old USING (page_id)
SET now.content = old.content, now.editor = 'Ada', now.summary = 'restored the text of 12:02'
WHERE now.page_id = 1;

-- 5. A DELETE ends the row's last version. The table no longer has the page ...
SET timestamp = UNIX_TIMESTAMP('2026-11-01 12:05:00');
DELETE FROM lab_page WHERE page_id = 1;

SELECT COUNT(*) AS rows_in_the_table_after_delete,
       (SELECT COUNT(*) FROM lab_page FOR SYSTEM_TIME ALL WHERE page_id = 1) AS versions_still_kept
FROM lab_page
WHERE page_id = 1;

--    ... but its history does, so the page can be brought back: insert the newest
--    version found in the history as a new current row.
SET timestamp = UNIX_TIMESTAMP('2026-11-01 12:06:00');
INSERT INTO lab_page (page_id, title, content, editor, summary)
SELECT page_id, title, content, 'Ada', 'undeleted'
FROM lab_page FOR SYSTEM_TIME ALL
WHERE page_id = 1
ORDER BY ROW_END DESC
LIMIT 1;

-- Back to the real clock for everything that follows.
SET timestamp = DEFAULT;

-- What the server kept: seven statements, six versions (the DELETE ended one, it did
-- not add one). The gap between 12:05 and 12:06 is the minute the page did not exist.
SELECT TIME(ROW_START) AS from_time,
       IF(ROW_END > CURRENT_TIMESTAMP(6), 'still current', TIME(ROW_END)) AS to_time,
       editor, summary, content
FROM lab_page FOR SYSTEM_TIME ALL
WHERE page_id = 1
ORDER BY ROW_START;

-- The page at three moments: before the vandalism, during it, and while it was deleted.
SELECT '12:02:30' AS as_of, content FROM lab_page FOR SYSTEM_TIME AS OF TIMESTAMP '2026-11-01 12:02:30' WHERE page_id = 1
UNION ALL
SELECT '12:03:30', content FROM lab_page FOR SYSTEM_TIME AS OF TIMESTAMP '2026-11-01 12:03:30' WHERE page_id = 1
UNION ALL
SELECT '12:05:30', content FROM lab_page FOR SYSTEM_TIME AS OF TIMESTAMP '2026-11-01 12:05:30' WHERE page_id = 1;
