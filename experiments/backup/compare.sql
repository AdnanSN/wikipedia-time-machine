-- experiments/backup/compare.sql: does a backup bring the history back?
--
-- Run by scripts/backup_check.py, which first dumps the two system-versioned tables of
-- wiki_time_machine twice and restores each dump into its own database:
--
--   wtm_restored        from  mariadb-dump --dump-history   (MariaDB 10.11 and later)
--   wtm_restored_plain  from  mariadb-dump                  (the default)
--
-- This script compares both with the original and drops them again.

USE wtm_restored;
SET time_zone = '+00:00';

-- What each backup brought back.
SELECT 'the original' AS database_is,
       (SELECT COUNT(*) FROM wiki_time_machine.article) AS current_articles,
       (SELECT COUNT(*) FROM wiki_time_machine.article FOR SYSTEM_TIME ALL) AS article_versions,
       (SELECT MIN(row_start) FROM wiki_time_machine.article FOR SYSTEM_TIME ALL) AS oldest_version_starts
UNION ALL
SELECT 'restored from --dump-history',
       (SELECT COUNT(*) FROM wtm_restored.article),
       (SELECT COUNT(*) FROM wtm_restored.article FOR SYSTEM_TIME ALL),
       (SELECT MIN(row_start) FROM wtm_restored.article FOR SYSTEM_TIME ALL)
UNION ALL
SELECT 'restored from a default dump',
       (SELECT COUNT(*) FROM wtm_restored_plain.article),
       (SELECT COUNT(*) FROM wtm_restored_plain.article FOR SYSTEM_TIME ALL),
       (SELECT MIN(row_start) FROM wtm_restored_plain.article FOR SYSTEM_TIME ALL);

CREATE OR REPLACE TEMPORARY TABLE check_result (
  id   INT AUTO_INCREMENT PRIMARY KEY,
  test VARCHAR(200) NOT NULL,
  pass BOOLEAN NOT NULL
);

-- With --dump-history every version comes back with its own dates and its own text.
INSERT INTO check_result (test, pass)
SELECT 'a --dump-history backup restores every version of every article, dates and text included',
       (SELECT COUNT(*) FROM wtm_restored.article FOR SYSTEM_TIME ALL)
     = (SELECT COUNT(*) FROM wiki_time_machine.article FOR SYSTEM_TIME ALL)
   AND NOT EXISTS (SELECT 1 FROM wiki_time_machine.article FOR SYSTEM_TIME ALL AS a
                     LEFT JOIN wtm_restored.article FOR SYSTEM_TIME ALL AS b
                       ON b.page_id = a.page_id AND b.row_end = a.row_end
                    WHERE b.rev_id IS NULL OR b.rev_id <> a.rev_id OR b.row_start <> a.row_start
                       OR NOT SHA1(b.content) <=> SHA1(a.content));

INSERT INTO check_result (test, pass)
SELECT 'the restored table answers AS OF like the original (the MariaDB article on 1 June 2010)',
       (SELECT rev_id FROM wtm_restored.article FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00' WHERE page_id = 24960699)
     = (SELECT rev_id FROM wiki_time_machine.article FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00' WHERE page_id = 24960699);

INSERT INTO check_result (test, pass)
SELECT 'the lab table, whose period columns are hidden, comes back with its history too',
       (SELECT COUNT(*) FROM wtm_restored.lab_page FOR SYSTEM_TIME ALL)
     = (SELECT COUNT(*) FROM wiki_time_machine.lab_page FOR SYSTEM_TIME ALL)
   AND (SELECT content FROM wtm_restored.lab_page FOR SYSTEM_TIME AS OF TIMESTAMP '2026-11-01 12:03:30' WHERE page_id = 1)
     = 'MARIADB IS A KIND OF SEAL';

-- Without it, the backup holds the current rows only, and they are restored as rows
-- that came into being at the moment of the restore. Nothing warns about it.
INSERT INTO check_result (test, pass)
SELECT 'a default dump brings back the current rows only, stamped with the time of the restore',
       (SELECT COUNT(*) FROM wtm_restored_plain.article FOR SYSTEM_TIME ALL)
     = (SELECT COUNT(*) FROM wiki_time_machine.article)
   AND (SELECT MIN(row_start) FROM wtm_restored_plain.article FOR SYSTEM_TIME ALL)
     > (SELECT MAX(row_start) FROM wiki_time_machine.article);

SELECT test, pass FROM check_result ORDER BY id;
SELECT CONCAT(SUM(pass), ' / ', COUNT(*), ' backup checks passed') AS summary FROM check_result;

DELIMITER //
BEGIN NOT ATOMIC
  IF EXISTS (SELECT 1 FROM check_result WHERE NOT pass) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A backup check failed: see the rows with pass = 0';
  END IF;
END //
DELIMITER ;

DROP DATABASE wtm_restored;
DROP DATABASE wtm_restored_plain;
