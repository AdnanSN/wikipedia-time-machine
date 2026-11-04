-- 02_build_history.sql: rebuild Wikipedia's revision history as a system-versioned table.
--
-- Each revision becomes one version of its article's row in `article`. The version
-- starts when the revision was saved and ends when the next revision of the same
-- article was saved; the newest revision is the current row.
--
-- Normally the server stamps a row with the time of the statement that wrote it, so a
-- plain import would record when this script ran, not when anyone edited Wikipedia.
-- system_versioning_insert_history (MariaDB 10.11 and later) lets us write row_start and
-- row_end ourselves. It works only while secure_timestamp allows changing the session
-- timestamp, which it does by default. docs/decisions/0001-time-model.md compares this
-- with the other options.

USE wiki_time_machine;
SET time_zone = '+00:00';  -- Wikipedia's timestamps are UTC; TIMESTAMP columns convert
                           -- to and from the session time zone, so keep it at UTC.

-- When each revision was the current text: from its save to the article's next save.
-- Wikipedia stores save times to the second, so two saves of one article can share a
-- timestamp. MariaDB refuses a version that starts and ends at the same instant (error
-- 4112, "Incorrect system-version range"), and it adds row_end to the primary key, so
-- revisions saved in the same second are spread 1 microsecond apart, in revision-id
-- order. replaced_at is NULL for the newest revision of each article.
CREATE OR REPLACE VIEW revision_period AS
SELECT rev_id, rev_page, saved_at,
       LEAD(saved_at) OVER (PARTITION BY rev_page ORDER BY saved_at) AS replaced_at
FROM (SELECT rev_id, rev_page,
             rev_timestamp + INTERVAL (ROW_NUMBER() OVER (PARTITION BY rev_page, rev_timestamp
                                                          ORDER BY rev_id) - 1) MICROSECOND
               AS saved_at
      FROM revision) AS saved;

SET @@session.system_versioning_insert_history = 1;

-- Past versions: we give both ends of the period.
INSERT INTO article (page_id, title, rev_id, editor, summary, minor_edit, len, sha1, tags,
                     content, row_start, row_end)
SELECT r.rev_page, p.page_title, r.rev_id, r.rev_actor, r.rev_comment, r.rev_minor_edit,
       r.rev_len, r.rev_sha1, r.rev_tags, r.content, v.saved_at, v.replaced_at
FROM revision AS r
JOIN page AS p ON p.page_id = r.rev_page
JOIN revision_period AS v ON v.rev_id = r.rev_id
WHERE v.replaced_at IS NOT NULL;

-- Current versions: we give only the start. The server sets row_end to its "still
-- current" value, which is 2038-01-19 03:14:07.999999 UTC before MariaDB 11.5 and
-- 2106-02-07 06:28:15.999999 UTC from 11.5 on 64-bit systems.
INSERT INTO article (page_id, title, rev_id, editor, summary, minor_edit, len, sha1, tags,
                     content, row_start)
SELECT r.rev_page, p.page_title, r.rev_id, r.rev_actor, r.rev_comment, r.rev_minor_edit,
       r.rev_len, r.rev_sha1, r.rev_tags, r.content, v.saved_at
FROM revision AS r
JOIN page AS p ON p.page_id = r.rev_page
JOIN revision_period AS v ON v.rev_id = r.rev_id
WHERE v.replaced_at IS NULL;

SET @@session.system_versioning_insert_history = 0;

SELECT COUNT(*) AS articles,
       (SELECT COUNT(*) FROM article FOR SYSTEM_TIME ALL) AS versions,
       (SELECT COUNT(*) FROM revision_period WHERE MICROSECOND(saved_at) > 0)
         AS same_second_saves_moved
FROM article;
