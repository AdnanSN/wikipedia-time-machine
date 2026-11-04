-- 03_time_machine.sql: the time machine, in SQL.
--
-- Every query here reads the system-versioned `article` table. Without FOR SYSTEM_TIME
-- a query sees only the current rows; with it, the server answers from the history.

USE wiki_time_machine;
SET time_zone = '+00:00';  -- the timestamps below are UTC

-- 1. An article as it stood at a moment you pick.
SELECT title, rev_id, row_start AS saved_at, row_end AS replaced_at, len AS bytes, editor
FROM article FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'
WHERE title = 'MariaDB';

-- 2. The whole data set as it stood on 1 January 2005: only the articles that existed then.
SELECT title, rev_id, row_start AS saved_at, len AS bytes
FROM article FOR SYSTEM_TIME AS OF TIMESTAMP '2005-01-01 00:00:00'
ORDER BY title;

-- 3. One article at many moments in one query. AS OF t is the same as
--    "row_start <= t AND t < row_end" over FOR SYSTEM_TIME ALL, so a join to a list of
--    dates does AS OF for each of them. Our university's article, renamed twice, with
--    the name it gives in bold (wikitext '''...''') at the start of every third year:
WITH RECURSIVE moment (at_time) AS (
  SELECT TIMESTAMP '2003-01-01 00:00:00'
  UNION ALL
  SELECT at_time + INTERVAL 3 YEAR FROM moment WHERE at_time < TIMESTAMP '2024-01-01 00:00:00'
)
SELECT m.at_time, a.rev_id, a.len AS bytes,
       TRIM(BOTH "'''" FROM REGEXP_SUBSTR(a.content, "'''[^'\\n]{3,60}'''")) AS name_in_bold
FROM moment AS m
JOIN article FOR SYSTEM_TIME ALL AS a
  ON a.row_start <= m.at_time AND m.at_time < a.row_end
WHERE a.title = 'Constructor University'
ORDER BY m.at_time;

--    The second rename, edit by edit: the versions current at some point between
--    November 2022 and March 2023 in which that bold name changed. The rename was
--    added and reverted several times, and once vandalised, before it stuck; for two
--    months after the page was moved, the article gave no name in bold at all.
SELECT saved_at, rev_id, name_in_bold
FROM (SELECT row_start AS saved_at, rev_id,
             TRIM(BOTH "'''" FROM REGEXP_SUBSTR(content, "'''[^'\\n]{3,60}'''")) AS name_in_bold,
             LAG(TRIM(BOTH "'''" FROM REGEXP_SUBSTR(content, "'''[^'\\n]{3,60}'''")))
               OVER (ORDER BY row_start) AS name_before
      FROM article FOR SYSTEM_TIME FROM TIMESTAMP '2022-11-01 00:00:00'
                                     TO TIMESTAMP '2023-03-01 00:00:00'
      WHERE title = 'Constructor University') AS version
WHERE NOT name_in_bold <=> name_before
ORDER BY saved_at;

-- 4. BETWEEN and FROM ... TO: every version that was current at some point in a range,
--    including the one already current when the range began. BETWEEN includes the end
--    point, FROM ... TO does not.
SELECT title, COUNT(*) AS versions_current_in_2025
FROM article FOR SYSTEM_TIME BETWEEN TIMESTAMP '2025-01-01 00:00:00'
                                 AND TIMESTAMP '2026-01-01 00:00:00'
GROUP BY title
ORDER BY versions_current_in_2025 DESC, title
LIMIT 10;

-- 5. FOR SYSTEM_TIME ALL: the history as data. Edits per year across all 30 articles.
SELECT YEAR(row_start) AS year, COUNT(*) AS edits, COUNT(DISTINCT page_id) AS articles_edited,
       ROUND(SUM(len) / 1e6, 1) AS mb_of_text_saved
FROM article FOR SYSTEM_TIME ALL
GROUP BY YEAR(row_start)
ORDER BY year;

-- 6. When did an idea first appear in an article?
SELECT title, MIN(row_start) AS first_mentioned_mariadb
FROM article FOR SYSTEM_TIME ALL
WHERE content LIKE '%MariaDB%' AND title <> 'MariaDB'
GROUP BY title
ORDER BY first_mentioned_mariadb;

-- 7. The edits that stood longest unchanged, and the ones reverted fastest.
SELECT title, rev_id, row_start AS saved_at,
       TIMESTAMPDIFF(DAY, row_start, LEAST(row_end, TIMESTAMP '2026-11-01 00:00:00')) AS days_unchanged
FROM article FOR SYSTEM_TIME ALL
ORDER BY days_unchanged DESC
LIMIT 5;

SELECT COUNT(*) AS reverted_edits,
       SUM(TIMESTAMPDIFF(SECOND, row_start, row_end) < 60) AS reverted_within_a_minute
FROM article FOR SYSTEM_TIME ALL
WHERE FIND_IN_SET('mw-reverted', tags);
