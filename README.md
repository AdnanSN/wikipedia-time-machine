A project for area 3, "System-versioned tables: history for free" for the [MariaDB student database projects, 2026-09](https://mariadb.org/bachelor_hackathon_2026-09/).

# Wikipedia time machine

[![CI](https://github.com/AdnanSN/wikipedia-time-machine/actions/workflows/ci.yml/badge.svg)](https://github.com/AdnanSN/wikipedia-time-machine/actions/workflows/ci.yml)

Wikipedia runs on MariaDB, but it keeps its history the way databases could not do for it in 2001: MediaWiki, its software, writes a new row into a `revision` table on every edit, and every "what did this page say then?" is a query the application has to write. MariaDB can keep that history itself. `WITH SYSTEM VERSIONING` makes a table remember every earlier version of its rows, and `FOR SYSTEM_TIME AS OF` reads the table as it stood at any moment.

This project loads the complete history of 30 Wikipedia articles, 13,354 revisions from 2002 to 2026, into one system-versioned table with the real save dates, and asks it what the articles said.

> **Status, 4 November 2026: milestone 1 of 7 is done.** The data set, the schema, the history load with real dates, the queries and the checks below work and run in CI. The web page, the growth and partitioning measurements, the measured comparison of the time models and the before-and-after comparison are planned; [docs/PLAN.md](docs/PLAN.md) says who builds what, by when.

## What we found so far

- **One clause replaces the revision-table query.** MediaWiki finds an article as it stood at time *t* by sorting its revisions and taking the newest one before *t*; here it is `FOR SYSTEM_TIME AS OF t`. The two give identical answers for every article on 1 January of every year from 2001 to 2026 (622 article-years, checked on every run).
- **The real work is the timestamps.** System versioning stamps rows with the time of the statement, so a plain import records when the script ran. We write the history rows directly with Wikipedia's save times, using `system_versioning_insert_history`. MariaDB refuses a version whose start equals its end (error 4112), and Wikipedia saves to the second, so the load spreads saves made in the same second 1 microsecond apart. [The decision and its alternatives](docs/decisions/0001-time-model.md).
- **The `mariadb` client hides errors in sourced files.** By default, `source` carries on after an error and the client exits with status 0, so a broken build looks like a good one. Every command in this repository uses `--abort-source-on-error`.

## Quick start

Requirements: MariaDB 10.11 or newer, for `system_versioning_insert_history`. Developed on **MariaDB 12.3.3** on Windows 11; [CI](#how-we-check-it) runs everything on 10.11, 11.4 and 12.3. Python 3.9 or newer, standard library only. No network access is needed: the data is in the repository.

```bash
git clone https://github.com/AdnanSN/wikipedia-time-machine.git
cd wikipedia-time-machine
python scripts/build_sql.py
mariadb -u root -p --table --abort-source-on-error -e "source run_all.sql"
```

The first command turns the compressed revisions into `build/load_revisions.sql` (167 MB, in about 15 seconds). The second drops and recreates the `wiki_time_machine` database, loads it, runs the demo queries and ends with `8 / 8 checks passed`, in about 10 seconds on a laptop. On Windows, if `mariadb` is not found, use its full path, `"C:\Program Files\MariaDB 12.3\bin\mariadb.exe"`, or let `python scripts/run_sql.py` find it: it runs the same command with the connection settings from a `.env` file (copy [.env.example](.env.example)).

Then ask it something:

```sql
USE wiki_time_machine;
SET time_zone = '+00:00';

SELECT title, rev_id, row_start AS saved_at, len AS bytes
FROM article FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'
WHERE title = 'MariaDB';
```

```
+---------+-----------+----------------------------+-------+
| title   | rev_id    | saved_at                   | bytes |
+---------+-----------+----------------------------+-------+
| MariaDB | 365034244 | 2010-05-30 15:09:42.000000 |  1184 |
+---------+-----------+----------------------------+-------+
```

On 1 June 2010 the MariaDB article was a 1,184-byte stub that called MariaDB "a community-developed branch of the MySQL database". Today it is 77,477 bytes, after 1,007 revisions.

## The data

[data/articles.txt](data/articles.txt) is the stated set: 30 articles on MariaDB and its storage engines, on how databases handle time and history, on transactions and on relational basics, plus our university's article. [scripts/fetch_revisions.py](scripts/fetch_revisions.py) downloaded every revision saved before **2026-11-01 00:00:00 UTC** from the MediaWiki API: 161.8 MB of wikitext, committed as 1.5 MB of xz files in [data/revisions/](data/revisions/), each revision checked against the SHA-1 Wikipedia reports for it. Because of the fixed cutoff, downloading again gives the same data. [data/README.md](data/README.md) has the file format, how the articles were chosen, and the licence (CC BY-SA 4.0).

## The data model

[sql/01_schema.sql](sql/01_schema.sql) creates three tables:

- **`page` and `revision`: history the way MediaWiki keeps it.** One row per article, one row per edit, written by application code. We load the downloaded revisions here first. The revision table is also our "before": the thing system versioning is meant to replace, kept for the comparisons.
- **`article`: history the way MariaDB keeps it.** One row per article holding its current text. The server keeps every earlier version.

```sql
CREATE TABLE article (
  page_id    INT UNSIGNED NOT NULL,
  title      VARCHAR(255) NOT NULL,
  rev_id     INT UNSIGNED NOT NULL,      -- the Wikipedia revision this version is
  editor     VARCHAR(255) NULL,
  summary    TEXT NULL,
  minor_edit BOOLEAN NOT NULL,
  len        INT UNSIGNED NULL,
  sha1       CHAR(40) NULL,
  tags       VARCHAR(1024) NULL,
  content    MEDIUMTEXT NULL,
  row_start  TIMESTAMP(6) GENERATED ALWAYS AS ROW START,
  row_end    TIMESTAMP(6) GENERATED ALWAYS AS ROW END,
  PERIOD FOR SYSTEM_TIME (row_start, row_end),
  PRIMARY KEY (page_id),
  UNIQUE KEY title (title)
) WITH SYSTEM VERSIONING;
```

Why it looks like this:

- **One row per article, not one per revision.** The revision is not an entity of its own here; it is a state of the article. Updating the row is what an edit is, and the history is what the server keeps. The primary key is `page_id`, and MariaDB silently adds `row_end` to it, so old versions can share the key.
- **The revision's metadata travels with the text.** `rev_id`, `editor`, `summary`, `minor_edit`, `tags` and `sha1` are ordinary columns, so each version still says which Wikipedia edit it was and who made it. System versioning itself records only when a row changed, not who changed it.
- **Explicit `row_start` and `row_end` with microseconds.** The period columns could be left implicit, but naming them lets queries show them and lets the load set them. Microseconds are needed for saves made in the same second.
- **Title as of the cutoff.** An article that was renamed keeps its page id; `title` is its name on 1 November 2026. Following renames through Wikipedia's move log is out of scope.

## How the history gets its real dates

The area brief calls this the real design question. A naive import gives "a perfect history of your own loading script and nothing about the article". We considered four options, described in [docs/decisions/0001-time-model.md](docs/decisions/0001-time-model.md): replaying the revisions with import-time stamps, replaying them with the session clock set to each save time, writing the history rows directly with `system_versioning_insert_history`, or an application-time period next to the system period (a bitemporal table).

We chose to write the history rows directly, because a Wikipedia save time *is* a transaction time: the moment Wikipedia's database committed the edit, which is exactly what a system period records. [sql/02_build_history.sql](sql/02_build_history.sql) computes each version's period from the revision table, then inserts the old versions with both ends and the current ones with only the start:

```sql
-- From each revision's save to the article's next save (simplified: the real view also
-- spreads saves made in the same second 1 microsecond apart).
CREATE OR REPLACE VIEW revision_period AS
SELECT rev_id, rev_page, rev_timestamp AS saved_at,
       LEAD(rev_timestamp) OVER (PARTITION BY rev_page ORDER BY rev_timestamp) AS replaced_at
FROM revision;

SET @@session.system_versioning_insert_history = 1;

INSERT INTO article (page_id, title, rev_id, ..., content, row_start, row_end)
SELECT ..., v.saved_at, v.replaced_at
FROM revision AS r JOIN page AS p ON ... JOIN revision_period AS v ON v.rev_id = r.rev_id
WHERE v.replaced_at IS NOT NULL;        -- old versions: both ends given

INSERT INTO article (page_id, title, rev_id, ..., content, row_start)
SELECT ..., v.saved_at
FROM ... WHERE v.replaced_at IS NULL;   -- current versions: the server sets row_end
```

The current rows are left to the server because "still current" is a different date on different versions: 2038-01-19 before MariaDB 11.5, 2106-02-07 from 11.5 on 64-bit systems. The whole history builds in one pass: 0.96 to 1.18 seconds over three runs, on MariaDB 12.3.3 on a Windows 11 laptop.

The price: the history is only as trustworthy as the loader. Anyone allowed to set `system_versioning_insert_history` can write history with any dates, and a server with `secure_timestamp = YES` refuses it. Milestone M4 builds the other options on the same data and measures them.

## The time machine in SQL

[sql/03_time_machine.sql](sql/03_time_machine.sql) runs these as part of `run_all.sql`. All times are UTC.

**An article at many moments, in one query.** `AS OF t` means `row_start <= t AND t < row_end`, so joining `FOR SYSTEM_TIME ALL` to a list of dates does `AS OF` for each of them. Here is the name our university's article gave in bold at the start of every third year:

```sql
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
```

| at_time | rev_id | bytes | name_in_bold |
|---------|-------:|------:|--------------|
| 2003-01-01 | 2751999 | 537 | International University Bremen |
| 2006-01-01 | 30811740 | 6873 | International University Bremen |
| 2009-01-01 | 258540533 | 18413 | Jacobs University Bremen |
| 2012-01-01 | 467019497 | 19861 | Jacobs University Bremen |
| 2015-01-01 | 633499912 | 15796 | Jacobs University Bremen |
| 2018-01-01 | 817138641 | 21032 | Jacobs University Bremen |
| 2021-01-01 | 996712520 | 25800 | Jacobs University Bremen |
| 2024-01-01 | 1186613612 | 27285 | Constructor University |

**A change, edit by edit.** `FOR SYSTEM_TIME FROM a TO b` returns every version that was current at some point in the range, including the one already current at *a*; `LAG()` over them finds the edits that changed the name. The second rename did not happen in one edit:

| saved_at (2022–23) | rev_id | name_in_bold |
|--------------------|-------:|--------------|
| 12 Oct 12:49 | 1115637950 | Jacobs University Bremen |
| 7 Nov 00:13 | 1120432013 | Constructor University Bremen |
| 8 Nov 21:15 | 1120793862 | Jacobs University Bremen |
| 26 Nov 21:36 | 1124003268 | Constructor University Bremen |
| 27 Nov 00:45 | 1124033939 | Jacobs University Bremen |
| 28 Nov 20:04:39 | 1124412138 | Bob the Builder University Bremen |
| 28 Nov 20:04:50 | 1124412181 | Jacobs University Bremen |
| 3 Dec 02:52 | 1125264309 | Constructor University Bremen |
| 5 Dec 13:51 | 1125721203 | Jacobs University Bremen |
| 7 Dec 10:41 | 1126073070 | North America (now US only) |
| 7 Dec 23:27:52 | 1126175693 | Con |
| 7 Dec 23:28:11 | 1126175740 | North America (now US only) |
| 10 Feb 21:05 | 1138653100 | Constructor University |

The new name was added and reverted three times in November and December 2022, and two vandal edits stood for 11 and 19 seconds. On 7 December an account named JacobsComm changed the name throughout and moved the page, but the opening sentence lost its bold name in the process: for two months the first bold text in the article was a label further down the page, "North America (now US only)".

**History as data.** `FOR SYSTEM_TIME ALL` turns the history into rows to aggregate. When did other articles first mention MariaDB?

```sql
SELECT title, MIN(row_start) AS first_mentioned_mariadb
FROM article FOR SYSTEM_TIME ALL
WHERE content LIKE '%MariaDB%' AND title <> 'MariaDB'
GROUP BY title
ORDER BY first_mentioned_mariadb;
```

The article on Michael Widenius, MariaDB's creator, mentioned it first, on 22 March 2009, seven months before the MariaDB article's first revision. Aria followed in June 2009 and InnoDB in July 2010; Temporal database only in January 2018, and the articles on valid time and transaction time in June 2024. The script also counts edits per year, finds the edits that stood unchanged longest, and counts the edits Wikipedia has tagged as reverted (it has done so since 2020): 171 in the set, 57 of which stood for less than a minute.

## Side by side: the revision table and the versioned table

The same question, the MariaDB article as it stood on 1 June 2010, both ways. Both return revision 365034244.

With the revision table, as MediaWiki does it:

```sql
SELECT p.page_title AS title, r.rev_id, r.rev_timestamp AS saved_at, r.rev_len AS bytes
FROM page AS p
JOIN revision AS r ON r.rev_page = p.page_id
WHERE p.page_title = 'MariaDB'
  AND r.rev_timestamp <= '2010-06-01 00:00:00'
ORDER BY r.rev_timestamp DESC, r.rev_id DESC
LIMIT 1;
```

With system versioning:

```sql
SELECT title, rev_id, row_start AS saved_at, len AS bytes
FROM article FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'
WHERE title = 'MariaDB';
```

For one article the difference is small. It grows with the question: "every article as it stood on that day" needs a window function or a correlated subquery over the revision table, and stays the same one clause with `AS OF`. The bigger difference is on the writing side: with the revision table, every piece of code that edits an article must also write the revision row; with `article`, an `UPDATE` is enough and the server cannot forget. Milestone M5 measures both sides, against a trigger-based history as you would build it on MySQL or PostgreSQL, neither of which has system versioning.

## How we check it

[sql/90_checks.sql](sql/90_checks.sql) runs at the end of every build and stops it with an error if any check fails:

| Check | What it guards against |
|-------|------------------------|
| every article has exactly one current version | a lost or duplicated current row |
| every revision is exactly one version | revisions dropped or duplicated by the load |
| the current version is the newest revision before the cutoff | the wrong revision ending up current |
| each version starts in the second its revision was saved | import-time stamps instead of Wikipedia's |
| each version ends exactly when the next one starts | gaps or overlaps in the history |
| the text is byte-for-byte what Wikipedia has | encoding or escaping damage (compares SHA-1s) |
| `AS OF` 1 January 2001–2026 matches the revision table | `AS OF` and MediaWiki's query disagreeing |
| two saves in the same second become two versions, 1 µs apart | error 4112 on another set of articles (tested on made-up rows, rolled back) |

[CI](.github/workflows/ci.yml) runs `fetch_revisions.py --check` (every file against `data/pages.tsv` and every SHA-1), then the whole build and the checks, on MariaDB 10.11, 11.4 and 12.3.

## What is next

| Milestone | Owner | Due |
|-----------|-------|-----|
| M2: the time machine page: pick an article and a moment, read it as it stood | Siddhartha | 17 Nov |
| M3: how the versioned table grows, and what partitioning by `SYSTEM_TIME` does about it | Rahmath | 17 Nov |
| M4: the time models compared and measured | Adnan | 20 Nov |
| M5: history by triggers and revision tables, and where system versioning stops being the right answer | Rahmath, Adnan | 24 Nov |
| M6: diff between two moments | Siddhartha | 24 Nov |
| M7: results, screenshots, self-evaluation, presentation (3 Dec) | everyone | 1 Dec |

## Files

| Path | What it is |
|------|------------|
| [data/](data/) | The article list, the revision history and its documentation |
| [scripts/fetch_revisions.py](scripts/fetch_revisions.py) | Downloads the history from the MediaWiki API, or checks the committed files (`--check`) |
| [scripts/build_sql.py](scripts/build_sql.py) | Writes `build/load_revisions.sql` from the committed files |
| [scripts/run_sql.py](scripts/run_sql.py) | Runs `run_all.sql` or any script with the settings from `.env`, so nothing has to be typed |
| [sql/](sql/) | Schema, history load, demo queries, checks |
| [run_all.sql](run_all.sql) | Runs everything in order |
| [docs/decisions/](docs/decisions/) | Design decisions and their alternatives |
| [docs/PLAN.md](docs/PLAN.md) | Milestones, owners, and what each part can rely on |

## Team

The Software Pioneers, Constructor University, Capstone I (fall 2026):

- **Adnan S**: data set, schema, history load, checks, CI (M1); time-model comparison (M4)
- **Siddhartha Adepu**: the time machine page and diff (M2, M6)
- **Rahmath Shareef**: growth and partitioning (M3); the trigger-based baseline (M5)

How we work: [CONTRIBUTING.md](CONTRIBUTING.md). We use AI coding tools and record every use, with its prompt, in [docs/AI_USE.md](docs/AI_USE.md).
