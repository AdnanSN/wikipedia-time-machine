-- 90_checks.sql: checks that the versioned table holds exactly Wikipedia's history.
--
-- Prints one row per check (pass = 1 when it holds) and a summary line, and then stops
-- with an error if any check failed, so `mariadb < run_all.sql` and CI fail loudly.

USE wiki_time_machine;
SET time_zone = '+00:00';

CREATE OR REPLACE TEMPORARY TABLE check_result (
  id   INT AUTO_INCREMENT PRIMARY KEY,
  test VARCHAR(200) NOT NULL,
  pass BOOLEAN NOT NULL
);

INSERT INTO check_result (test, pass)
SELECT 'every article has exactly one current version',
       (SELECT COUNT(*) FROM article) = (SELECT COUNT(*) FROM page)
   AND (SELECT COUNT(DISTINCT page_id) FROM article) = (SELECT COUNT(*) FROM page);

INSERT INTO check_result (test, pass)
SELECT 'every revision is exactly one version',
       (SELECT COUNT(*) FROM article FOR SYSTEM_TIME ALL) = (SELECT COUNT(*) FROM revision)
   AND NOT EXISTS (SELECT 1 FROM revision AS r
                    WHERE r.rev_id NOT IN (SELECT rev_id FROM article FOR SYSTEM_TIME ALL));

INSERT INTO check_result (test, pass)
SELECT 'the current version is the newest revision before the cutoff',
       NOT EXISTS (SELECT 1 FROM article AS a JOIN page AS p USING (page_id)
                    WHERE a.rev_id <> p.page_latest);

INSERT INTO check_result (test, pass)
SELECT 'each version starts in the second its revision was saved',
       NOT EXISTS (SELECT 1 FROM article FOR SYSTEM_TIME ALL AS a
                     JOIN revision AS r USING (rev_id)
                    WHERE a.row_start < r.rev_timestamp
                       OR a.row_start >= r.rev_timestamp + INTERVAL 1 SECOND);

INSERT INTO check_result (test, pass)
SELECT 'each version ends exactly when the next one starts: no gaps, no overlaps',
       NOT EXISTS (SELECT 1
                     FROM (SELECT row_end,
                                  LEAD(row_start) OVER (PARTITION BY page_id ORDER BY row_start)
                                    AS next_start
                             FROM article FOR SYSTEM_TIME ALL) AS chain
                    WHERE next_start IS NOT NULL AND next_start <> row_end);

INSERT INTO check_result (test, pass)
SELECT 'the text is byte-for-byte what Wikipedia has (SHA-1 matches)',
       NOT EXISTS (SELECT 1 FROM article FOR SYSTEM_TIME ALL
                    WHERE content IS NOT NULL AND sha1 IS NOT NULL AND SHA1(content) <> sha1);

-- FOR SYSTEM_TIME AS OF against the query MediaWiki needs on its revision table, at
-- half a second past midnight on 1 January of every year. (Half a second, because two
-- saves in the same second are only ordered by revision id; see 02_build_history.sql.)
CREATE OR REPLACE TEMPORARY TABLE probe_as_of (
  at_time DATETIME(6), page_id INT UNSIGNED, rev_id INT UNSIGNED, PRIMARY KEY (at_time, page_id));
CREATE OR REPLACE TEMPORARY TABLE probe_revision (
  at_time DATETIME(6), page_id INT UNSIGNED, rev_id INT UNSIGNED, PRIMARY KEY (at_time, page_id));

DELIMITER //
BEGIN NOT ATOMIC
  DECLARE y INT DEFAULT 2001;
  DECLARE t DATETIME(6);
  WHILE y <= 2026 DO
    SET t = TIMESTAMP(CONCAT(y, '-01-01 00:00:00.5'));
    INSERT INTO probe_as_of
      SELECT t, page_id, rev_id FROM article FOR SYSTEM_TIME AS OF t;
    INSERT INTO probe_revision
      SELECT t, rev_page, rev_id
        FROM (SELECT rev_page, rev_id,
                     ROW_NUMBER() OVER (PARTITION BY rev_page
                                        ORDER BY rev_timestamp DESC, rev_id DESC) AS newest
                FROM revision WHERE rev_timestamp <= t) AS r
       WHERE newest = 1;
    SET y = y + 1;
  END WHILE;
END //
DELIMITER ;

INSERT INTO check_result (test, pass)
SELECT CONCAT('AS OF 1 January ', '2001-2026 matches the revision table (',
              (SELECT COUNT(*) FROM probe_as_of), ' article-years)'),
       (SELECT COUNT(*) FROM probe_as_of) = (SELECT COUNT(*) FROM probe_revision)
   AND NOT EXISTS (SELECT 1 FROM probe_as_of AS a
                     LEFT JOIN probe_revision AS r USING (at_time, page_id)
                    WHERE r.rev_id IS NULL OR r.rev_id <> a.rev_id);

-- Two saves in the same second. None of our 30 articles has one, so try it on a made-up
-- article inside a transaction, and roll it back. The result is kept in a user variable,
-- because the rollback also undoes rows written to check_result.
START TRANSACTION;
INSERT INTO page (page_id, page_title, page_latest)
VALUES (4000000000, 'Check: two saves in one second', 4000000003);
INSERT INTO revision (rev_id, rev_page, rev_parent_id, rev_timestamp, rev_minor_edit,
                      rev_actor, rev_comment, rev_len, rev_sha1, rev_tags, rev_deleted, content)
VALUES (4000000001, 4000000000, NULL,       '2020-01-01 12:00:00', 0, 'check', NULL, 1, NULL, NULL, 0, 'a'),
       (4000000002, 4000000000, 4000000001, '2020-01-01 12:00:00', 0, 'check', NULL, 1, NULL, NULL, 0, 'b'),
       (4000000003, 4000000000, 4000000002, '2020-01-01 12:00:05', 0, 'check', NULL, 1, NULL, NULL, 0, 'c');
SET @@session.system_versioning_insert_history = 1;
INSERT INTO article (page_id, title, rev_id, minor_edit, content, row_start, row_end)
SELECT 4000000000, 'Check: two saves in one second', v.rev_id, 0, r.content, v.saved_at, v.replaced_at
FROM revision_period AS v JOIN revision AS r USING (rev_id)
WHERE v.rev_page = 4000000000 AND v.replaced_at IS NOT NULL;
INSERT INTO article (page_id, title, rev_id, minor_edit, content, row_start)
SELECT 4000000000, 'Check: two saves in one second', v.rev_id, 0, r.content, v.saved_at
FROM revision_period AS v JOIN revision AS r USING (rev_id)
WHERE v.rev_page = 4000000000 AND v.replaced_at IS NULL;
SET @@session.system_versioning_insert_history = 0;
SELECT GROUP_CONCAT(content, '@', DATE_FORMAT(row_start, '%H:%i:%s.%f') ORDER BY row_start)
       = 'a@12:00:00.000000,b@12:00:00.000001,c@12:00:05.000000'
   AND (SELECT content FROM article WHERE page_id = 4000000000) = 'c'
  INTO @same_second_ok
FROM article FOR SYSTEM_TIME ALL WHERE page_id = 4000000000;
ROLLBACK;

INSERT INTO check_result (test, pass)
SELECT 'two saves in the same second become two versions, 1 microsecond apart',
       COALESCE(@same_second_ok, FALSE)
   AND NOT EXISTS (SELECT 1 FROM page WHERE page_id = 4000000000);

SELECT test, pass FROM check_result ORDER BY id;
SELECT CONCAT(SUM(pass), ' / ', COUNT(*), ' checks passed') AS summary FROM check_result;

DELIMITER //
BEGIN NOT ATOMIC
  IF EXISTS (SELECT 1 FROM check_result WHERE NOT pass) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A check failed: see the rows with pass = 0';
  END IF;
END //
DELIMITER ;
