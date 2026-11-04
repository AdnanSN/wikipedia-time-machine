# Plan: the Wikipedia time machine

Final presentation: **Thursday 3 December 2026**. This file says who does what by when. Change it in a pull request, like everything else, and keep the status column current.

## What MariaDB grades

Area 3's own criteria, each tagged with the general criterion it counts towards, and the milestone that covers it:

| Criterion from the area brief | Counts towards | Milestone |
|-------------------------------|----------------|-----------|
| A system-versioned table holding real Wikipedia revisions, queried with `FOR SYSTEM_TIME` | depth | M1 |
| The time-modelling decision made deliberately and explained: import-time stamps, `system_versioning_insert_history`, or an application-time period | depth | M1 (decision), M4 (measured) |
| An article rendered as it stood at a moment the reader picks | usability | M2 |
| A load that runs from the README against a stated set of articles | usability | M1 |
| How the versioned table grows, and what partitioning by `SYSTEM_TIME` does about it | execution | M3 |
| What history in the database replaces, and where it stops being the right answer | documentation | M5 |

On top of these, the four general criteria (documentation, MariaDB depth, execution, usability) and the team guide's product outcomes: compare against other databases before and after, repeat measurements and state the setup, say where the limits are. The page's evaluation prompt is what we run on ourselves in M7.

## Milestones

| # | Milestone | Share | Owner | Due | Status |
|---|-----------|-------|-------|-----|--------|
| M1 | Foundation: data set, schema, history load with real dates, `FOR SYSTEM_TIME` demos, checks, CI | 25% | Adnan | 4 Nov | done |
| M2 | The time machine page: pick an article and a moment, read it as it stood; revision timeline | 20% | Siddhartha | 17 Nov | not started |
| M3 | Growth, and partitioning by `SYSTEM_TIME`: measured | 20% | Rahmath | 17 Nov | not started |
| M4 | The time model compared: replay, `insert_history` and bitemporal, measured | 15% | Adnan | 20 Nov | not started |
| M5 | Before and after: history by triggers and revision tables (the MySQL, PostgreSQL and MediaWiki way), and where system versioning stops being the right answer | 10% | Rahmath (triggers baseline), Adnan (limits) | 24 Nov | not started |
| M6 | Diff between two moments | 5% | Siddhartha | 24 Nov | not started |
| M7 | Final README with screenshots and results, self-evaluation with MariaDB's prompt, presentation | 5% | everyone | 1 Dec | not started |

Weekly targets: by the meeting of week 46 (from 9 Nov), everyone is set up and has a first pull request open. By week 47, M2 and M3 are reviewed and merged. Week 48 is for M4 to M6. Week 49 is for M7 and rehearsing.

## M2: the time machine page (Siddhartha)

Branch `siddhartha/time-machine-page`. Owns `app/` and `docs/images/`.

A small web app in Python (Flask and PyMySQL, listed in `app/requirements.txt`):

- `/` lists the 30 articles, with how many versions each has and since when.
- `/article/<page_id>?at=2015-06-01T12:00` shows the article as it stood at that moment: the title, which revision that was (revision id, saved at, editor, edit summary, a link to `https://en.wikipedia.org/w/index.php?oldid=<rev_id>`), and the text rendered from wikitext to simple HTML. Headings, paragraphs, bold, italics, links and lists are enough; templates, tables, references and images may be left out, and the page should say so.
- A date and time picker, plus "previous edit" and "next edit" buttons.
- `/article/<page_id>/history`: the article's versions (from `FOR SYSTEM_TIME ALL`), each linking to its moment.
- Every query reads `article` with `FOR SYSTEM_TIME`. None reads `revision`.
- Connection settings from the same `.env` file and keys that `scripts/run_sql.py` reads (see `.env.example`), with environment variables taking precedence: `WTM_DB_HOST` (default `127.0.0.1`), `WTM_DB_PORT` (`3306`), `WTM_DB_USER` (`root`), `WTM_DB_PASSWORD`, `WTM_DB_NAME` (`wiki_time_machine`). Each connection runs `SET time_zone = '+00:00'`, and the page says the times are UTC.
- `app/README.md` says how to install and run it; tests for the wikitext renderer with `pytest`.

**Done when** someone else can run it from a fresh clone by following `app/README.md`, "Constructor University" at 1 January 2005 shows the International University Bremen text and today shows Constructor University, a screenshot is in `docs/images/`, and Adnan or Rahmath has approved the pull request.

## M3: growth and partitioning (Rahmath)

Branch `rahmath/growth-partitioning`. Owns `experiments/growth/` and `docs/growth-and-partitioning.md`.

- **Growth:** how big `article` is, current rows against history rows (`information_schema.TABLES`, and `information_schema.PARTITIONS` once partitioned); bytes of history per edit; how the history grew year by year (from `FOR SYSTEM_TIME ALL`).
- **Partitioning:** a copy of `article` partitioned by `SYSTEM_TIME`, for example `PARTITION BY SYSTEM_TIME INTERVAL 1 YEAR STARTS '2002-01-01 00:00:00' AUTO`, loaded the same way as `sql/02_build_history.sql` does. Show the rows and bytes per partition; `EXPLAIN PARTITIONS` for a current-only query, an `AS OF` query and an `ALL` query; and the time of current-only queries with and without partitioning (at least 5 runs each, median, MariaDB version and machine stated).
- **Removing old history:** `DELETE HISTORY ... BEFORE SYSTEM_TIME` against `ALTER TABLE ... DROP PARTITION`: time taken, what each leaves behind, the `DELETE HISTORY` privilege.
- Optional: `content MEDIUMTEXT COMPRESSED` and its effect on size; a larger article set to make growth easier to see (agree on it with Adnan first, since `data/articles.txt` is shared).
- Everything reproducible with one command, e.g. `python scripts/run_sql.py experiments/growth/run.sql`.

**Done when** `docs/growth-and-partitioning.md` answers "how does the versioned table grow, and what does partitioning by `SYSTEM_TIME` do about it?" with numbers, the method and its limits, and Adnan has approved it.

## M4: the time model compared (Adnan)

Branch `adnan/time-model-comparison`. Build options A′ (replay with the session clock set) and C (bitemporal) from [decision 0001](decisions/0001-time-model.md) next to B, measure load time, size and `AS OF` query time for each over five runs, and update the decision record and README with the results.

## M5: before and after (Rahmath, Adnan)

- **Rahmath**, branch `rahmath/before-after`, owns `experiments/before-after/`: history without system versioning, as you would build it on MySQL or PostgreSQL: a plain table plus a history table filled by triggers. Compare with `article`: lines of SQL, the "as it stood at *t*" query each needs, its speed, and what the triggers miss.
- **Adnan**: where system versioning stops being the right answer (for example: redacting one bad revision, recording who made a change, retention rules, schema changes, replication with `secure_timestamp`).
- Together: `docs/before-and-after.md`.

## M6: diff between two moments (Siddhartha)

`/article/<page_id>/diff?from=...&to=...`, using Python's `difflib` on the two texts as they stood.

## M7: finish (everyone)

README with screenshots and results tables, MariaDB's evaluation prompt run on `main` and its findings fixed, the presentation and a rehearsal.

## What the other milestones can rely on

Built by `run_all.sql`, defined in [sql/01_schema.sql](../sql/01_schema.sql). Changes go through Adnan, because every milestone depends on them.

- Database `wiki_time_machine`.
- `article`, system-versioned: `page_id`, `title`, `rev_id`, `editor`, `summary`, `minor_edit`, `len`, `sha1`, `tags`, `content`, and the period columns `row_start` and `row_end` (UTC). One current row per article; every older revision is a history row whose period runs from its save time to the next save.
- `page` and `revision`: Wikipedia's own way of keeping history. For comparisons only.

Queries the app can start from:

```sql
SET time_zone = '+00:00';

-- the articles, with the extent of their history
SELECT page_id, title, COUNT(*) AS versions, MIN(row_start) AS first_saved
FROM article FOR SYSTEM_TIME ALL
GROUP BY page_id, title
ORDER BY title;

-- one article as it stood at a moment
SELECT title, rev_id, row_start, row_end, editor, summary, content
FROM article FOR SYSTEM_TIME AS OF TIMESTAMP '2015-06-01 12:00:00'
WHERE page_id = 104185;

-- its timeline
SELECT rev_id, row_start, row_end, editor, summary, len, minor_edit
FROM article FOR SYSTEM_TIME ALL
WHERE page_id = 104185
ORDER BY row_start;
```
