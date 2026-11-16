# How the versioned table grows, and what partitioning by SYSTEM_TIME does about it

Milestone M3. Everything on this page comes from one script, [experiments/growth/run.sql](../experiments/growth/run.sql), and its output on our machine, [experiments/growth/results-mariadb-12.3.3.txt](../experiments/growth/results-mariadb-12.3.3.txt). Run it yourself with:

```bash
python scripts/run_sql.py experiments/growth/run.sql
```

## The short answers

- **It grows by a whole row per edit.** The table holds 30 current rows (0.4 MB of text) and 13,324 history rows (161.3 MB). An average edit changes the article's length by 194 bytes and stores 12,137: 63 bytes kept for every byte changed.
- **Partitioning by `SYSTEM_TIME` gives the current data its speed back.** With the history in yearly partitions, a search through the current texts takes 2.2 ms instead of 993 ms, because it no longer reads 13,324 old versions to find 30 current ones. Queries about the past gain only if the moment is recent, and a lookup of one article by key gets slightly slower.
- **Partitioning also makes forgetting cheap:** dropping thirteen years of history takes 50 to 97 ms as `DROP PARTITION` and 543 to 1,154 ms as `DELETE HISTORY`, and only the first gives the disk space back.
- **Dated history and automatic partitions do not mix.** Loaded the obvious way, the table answers correctly until its first `UPDATE` and returns nothing afterwards. [The trap, and three ways out](#the-trap-dated-history-and-partitions-that-do-not-exist-yet).
- **A time-travel lookup reads every later version** unless you tell it not to: 990 rows to return one, or 1 row with `ORDER BY row_end LIMIT 1`.
- **Partitioning does not make the history smaller.** Compressing the text column does (37% of the size), and so does storing each distinct text once (33%).

## Method

- **Machine:** Intel Core i5-13450HX (10 cores), 16 GB RAM, NVMe SSD, Windows 11. **MariaDB 12.3.3** with its default configuration, which matters here: the InnoDB buffer pool is 128 MB, smaller than the 223 MB table.
- **Data:** the project's `article` table, 13,354 versions of 30 articles, built by `run_all.sql`. The experiment makes its own copies in a database `wtm_growth` and drops it at the end.
- **Timing:** [experiments/harness.sql](../experiments/harness.sql). Each statement is prepared once, run once untimed to warm the caches, then run 7 times, each run timed inside the server with `SYSDATE(6)`. Statements end in `INTO @variable`, so no result travels to the client. The tables below give the **median**, with the fastest and slowest run in brackets where the spread matters. The removal test rebuilds its table before each of 3 runs.
- **Sizes** are `DATA_LENGTH + INDEX_LENGTH` from `information_schema` after `ANALYZE TABLE`; **row counts** are counted, never taken from `TABLE_ROWS` ([why](#what-information_schema-says)).
- **Checks:** the script ends with 9 checks of its own (every copy returns every text unchanged, every row is in the partition it belongs in, the partitioned table answers `AS OF` like the plain one at 27 moments, ...) and stops with an error if one fails.
- **Limits:** one machine, one run of the script, a laptop with other programs open. Sub-millisecond medians are at the edge of what this stopwatch resolves; read them as "well under a millisecond". The data set is small (223 MB); the ratios are what carries over to a larger one, the milliseconds are not. CI runs the same script on MariaDB 10.11, 11.4 and 12.3 with one timed run, to verify the statements and the checks, not the timings.

## How it grows

**A whole row per edit.** System versioning keeps the old row when a row changes. Our row carries the article's text, so every edit stores the whole article again:

| | versions | text | average size |
|---|---:|---:|---:|
| current rows (what a plain `SELECT` sees) | 30 | 0.4 MB | 14,828 bytes |
| history rows | 13,324 | 161.3 MB | 12,107 bytes |

On disk the table is 223.1 MB: 1.4 times its text, because InnoDB stores a long text in pages of its own and does not fill them all.

```sql
-- What one edit costs: bytes stored against bytes of length changed.
SELECT COUNT(*) AS edits, ROUND(AVG(len)) AS bytes_stored_per_edit,
       ROUND(AVG(ABS(change_in_length))) AS bytes_of_length_changed_per_edit
FROM (SELECT len, CAST(len AS SIGNED)
                  - CAST(LAG(len) OVER (PARTITION BY page_id ORDER BY row_start) AS SIGNED) AS change_in_length
      FROM article FOR SYSTEM_TIME ALL) AS edit
WHERE change_in_length IS NOT NULL;
```

13,324 edits stored 12,137 bytes each to record a change in length of 194 bytes on average. (The change in length understates how much text an edit touched, but the proportion is the point.) For comparison: the same 13,354 versions, compressed together with xz, are the 1.5 MB in [data/revisions/](../data/revisions/), because each version repeats most of the one before. A row-versioned table cannot use that; it does not know that two rows are almost the same text.

**Reverts are stored in full, again.** 1,872 versions (14.0%) have exactly the text an earlier version of the same article had: vandalism undone, edit wars, restored sections. They take 21.1 MB.

**Year by year,** from `FOR SYSTEM_TIME ALL` grouped by the year of `row_start`:

| year | edits | versions so far | MB so far |
|---|---:|---:|---:|
| 2002 | 16 | 16 | 0.0 |
| 2006 | 934 | 1,664 | 7.5 |
| 2010 | 1,188 | 5,839 | 45.7 |
| 2014 | 675 | 9,232 | 85.5 |
| 2018 | 478 | 11,089 | 113.4 |
| 2022 | 290 | 12,336 | 135.8 |
| 2026 | 226 | 13,354 | 161.8 |

The edits per year fell by four fifths after 2010, but the megabytes per year fell much less, because the articles got longer: 226 edits in 2026 stored 8.5 MB, 1,188 edits in 2010 stored 13.2 MB.

### What information_schema says

`information_schema.TABLES.TABLE_ROWS` is InnoDB's estimate. For this table it said 11,034 on the run recorded here and 2,390 and 2,482 on earlier runs; the table has 13,354 rows. Do not size a history from it. The same estimate decides when history partitions rotate by `LIMIT`, which is one reason that kind of rotation is only approximate.

### A table that lived through its edits is larger

The 223 MB above belong to a table loaded in one go. [experiments/time-models/run.sql](../experiments/time-models/run.sql) also builds the same history the way a live site would, one `UPDATE` per edit, and the result is not the same size. The numbers are in [the time-model decision](decisions/0001-time-model.md#what-a-replay-leaves-behind); in short, the replayed table needs noticeably more space until it is rebuilt with `ALTER TABLE ... FORCE`, and on a 128 MB buffer pool that difference decides whether a scan of it runs in memory or from disk.

## Storing it smaller

Two designs that keep the time machine and shrink the table, each verified to return every text of every version unchanged (by SHA-1):

| design | on disk | of plain |
|---|---:|---:|
| `article`: one full text per version | 223.1 MB | 100% |
| `content MEDIUMTEXT COMPRESSED` | 82.1 MB | 37% |
| versioned row + each distinct text once | 74.1 MB | 33% |

**Column compression** is a MariaDB attribute of the column, independent of the storage engine: `ALTER TABLE article MODIFY content MEDIUMTEXT COMPRESSED NULL`. Queries do not change.

**Text kept apart** is the shape of MediaWiki's own storage, with the server keeping the versions. The versioned row keeps only the SHA-1 of its text; an ordinary table holds each distinct text once (11,473 texts for 13,354 versions), compressed:

```sql
CREATE TABLE article_text (
  text_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  sha1    CHAR(40) NOT NULL,
  content MEDIUMTEXT COMPRESSED NOT NULL,
  UNIQUE KEY sha1 (sha1)
);

-- The article as it stood: the versioned row of that moment, joined to its text.
SELECT t.content
FROM article_slim FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00' AS s
JOIN article_text AS t USING (sha1)
WHERE s.title = 'MariaDB';
```

A reverted-to text then costs 40 bytes instead of a whole article, and it has a second use: a text in an ordinary table can be blanked or deleted, which a history row cannot ([docs/before-and-after.md](before-and-after.md#removing-one-version)).

Neither design slowed reading in our measurements: one article with its text as of 2012 took 0.10 ms plain, 0.09 ms compressed and 0.12 ms split; listing all 13,354 versions without text took 2.5 ms, 3.4 ms and 1.7 ms.

We kept the plain table for the project itself. It is the one that matches the brief, a table definition and nothing else, and at 223 MB there is nothing to save. At Wikipedia's scale the split design is the one to start from.

## Partitioning by SYSTEM_TIME

One partition per year of history, one for the current rows:

```sql
CREATE TABLE article_part LIKE article;
ALTER TABLE article_part
  PARTITION BY SYSTEM_TIME INTERVAL 1 YEAR STARTS '2002-01-01 00:00:00' AUTO PARTITIONS 26;
```

26 is the 25 years from 2002 to 2026 plus the current partition; `AUTO` lets the server add a partition for each later year when it is first needed. The partitions are declared before any row is loaded, [for a reason](#the-trap-dated-history-and-partitions-that-do-not-exist-yet). Loaded with `INSERT ... SELECT * FROM article FOR SYSTEM_TIME ALL` under `system_versioning_insert_history`, each history row lands in the partition of the year it **ended** (`row_end`), from 12 rows in the partition for 2002 to 1,188 in the one for 2010, and the 30 current rows in theirs. The script counts every partition and checks it against `YEAR(row_end)`.

### Which partitions a query opens

`EXPLAIN PARTITIONS` on the 26-partition table:

| query | partitions opened |
|---|---|
| current rows (`SELECT ... FROM article_part WHERE len > 20000`) | `pn` only |
| `FOR SYSTEM_TIME AS OF '2020-06-01'` | 2020 to 2026 and `pn`: 8 of 26 |
| `FOR SYSTEM_TIME FROM '2010-03-01' TO '2010-09-01'` | 2010 to 2026 and `pn`: 18 of 26 |
| `FOR SYSTEM_TIME ALL` | all 26 |

The rule: a partition holds the versions that ended in its year, so the server can skip the years **before** the moment asked about (a version that ended earlier cannot be the answer) and never the years after it (a version current in 2010 may have ended in any later year). The earlier the moment, the less pruning helps.

### What it does to query times

The same statement against the plain table and the partitioned one, median of 7 runs:

| statement | plain | partitioned | |
|---|---:|---:|---|
| count the current articles over 20 kB (no index helps) | 2.40 ms | 0.06 ms | 39 times faster |
| search the current texts for a word (`LIKE`) | 993 ms | 2.2 ms | 447 times faster |
| one current article by its key | 0.06 ms | 0.09 ms | no gain |
| all articles as of 2020 | 7.06 ms | 0.73 ms | 10 times faster |
| all articles as of 2006 | 3.57 ms | 3.57 ms | the same |
| one article as of 2012, with text | 0.06 ms | 0.17 ms | 2.6 times slower |
| count every version (`ALL`) | 2.16 ms | 2.39 ms | the same |

What the numbers say:

- **Anything that scans the current data wins, and wins more the larger the rows it would otherwise wade through.** The search is the striking case: unpartitioned, it reads the text of all 13,354 versions (161 MB, not all of it in memory) and throws 13,324 of them away; partitioned, it reads 30. This is the gain the documentation promises, and here it is 447-fold.
- **A lookup by key gains nothing.** The primary key already leads straight to the current row.
- **The past is faster only when it is recent.** As of 2020 the server opens 8 partitions; as of 2006 it has to open 22 of the 26 and is no faster than without partitions.
- **A lookup of one old version by key is slower,** because the index is now 26 small indexes and the server asks several of them. At 0.17 ms it still does not matter.

So partitioning by `SYSTEM_TIME` is not a way to make time travel fast. It is a way to stop the present from paying for the past, and to manage the past in pieces.

## The trap: dated history and partitions that do not exist yet

Our first version of the partitioned table followed the obvious recipe, which is also what the plan for this milestone said:

```sql
... PARTITION BY SYSTEM_TIME INTERVAL 1 YEAR STARTS '2002-01-01 00:00:00' AUTO;
```

No `PARTITIONS 26`: let `AUTO` make them. Then the load, as in `sql/02_build_history.sql`. What the experiment records:

| step | observed | right would be |
|---|---:|---:|
| partitions after loading 24 years of history | 2 | |
| history rows in the partition for 2002 | 13,324 | 12 |
| articles `AS OF` 1 June 2010, after the load | 27 | 27 |
| ... one ordinary `UPDATE` of one row later: partitions | 26 | |
| history rows still in the partition for 2002 | 13,324 | 12 |
| articles `AS OF` 1 June 2010 | **0** | 27 |
| versions under `FOR SYSTEM_TIME ALL` | 13,355 | 13,355 |
| after `REPAIR TABLE` ("Moved 13312 misplaced rows"): rows in 2002 | 12 | 12 |
| articles `AS OF` 1 June 2010 | 27 | 27 |

An `INSERT` never creates history partitions, even one that writes history, so the whole history went into the one partition there was. That is legal, the last history partition takes whatever lies beyond it, and every query was right and every check passed. The first live edit then made `AUTO` create the 24 missing years without moving a row, and from that moment the server, trusting the layout, skipped the partition for 2002 for every later moment. The time machine returned nothing, without an error. `CHECK TABLE` noticed only then.

This is a consequence of [MDEV-29674](https://jira.mariadb.org/browse/MDEV-29674), open since 2022, that the report does not mention. [upstream/README.md](../upstream/README.md#1-a-time-machine-that-goes-blank-after-its-first-edit) has the two-row reproduction and what we suggest to MariaDB.

**Three ways out,** all verified by the script:

1. **Declare the history partitions before loading** (`... AUTO PARTITIONS 26`). Each row is then placed by its `row_end`. This is what the table above does.
2. **Add them by hand afterwards:** `ALTER TABLE ... ADD PARTITION (PARTITION p2003 HISTORY, PARTITION p2004 HISTORY)` moves the rows that belong after the last partition; we got 12, 56 and 13,256 rows in the three partitions, as it should be.
3. **`REPAIR TABLE`** once `AUTO` has acted.

Rotation by row count has the same weakness and one of its own: with `PARTITION BY SYSTEM_TIME LIMIT 2000 PARTITIONS 8`, one bulk `INSERT` put all 13,324 history rows into the first partition and none into the other six, because the server only switches partitions between statements.

## Removing old history

Two ways to forget everything that ended before 2015, each on its own copy of the partitioned table, rebuilt before each of 3 runs:

| | `DELETE HISTORY ... BEFORE SYSTEM_TIME '2015-01-01'` | `ALTER TABLE ... DROP PARTITION p0, ..., p12` |
|---|---:|---:|
| time | 543 to 1,154 ms | 50 to 97 ms |
| versions left | 4,152 | 4,152 |
| still allocated on disk | 248.3 MB | 121.7 MB |
| partitions left | 26 | 13 |
| privilege | `DELETE HISTORY` | `ALTER`, `DROP` |
| granularity | any moment | whole partitions |

Both leave the same 4,152 versions. `DROP PARTITION` is about ten times faster and gives the space back, because it removes files; `DELETE HISTORY` deletes row by row and leaves the emptied space inside the files for later use. Neither can remove the history of one article: `DELETE HISTORY` takes no `WHERE` ([docs/before-and-after.md](before-and-after.md#removing-one-version)).

**What is forgotten is forgotten silently.** After either, `FOR SYSTEM_TIME AS OF '2010-06-01'` returns 0 articles where it returned 27, with no error and no warning; as of 2020 all 30 are still there. A query cannot tell "this article did not exist then" from "its history was removed". An application that trims history has to remember, somewhere else, how far back the table can still be trusted.

## What growth does to AS OF

"This article as it stood at *t*" is a lookup by primary key, and MariaDB has silently made the primary key `(page_id, row_end)`. The server starts at the first version that ended after *t*, which is the answer, and then reads on through every later version of the article, because nothing tells it that the versions of one row do not overlap. (They always do not, for history the server wrote itself. But `system_versioning_insert_history` lets anyone write history that does, so the server cannot assume it.)

Rows read to return one version of the MariaDB article, which has 1,007:

| moment | rows read | with text, median (fastest) |
|---|---:|---:|
| as of 2010 | 990 | 3.02 ms (2.66) |
| as of 2014 | 740 | |
| as of 2018 | 508 | 2.55 ms (2.22) |
| as of 2022 | 262 | |
| as of 2026 | 77 | 1.74 ms (1.24) |
| as of 2010, `ORDER BY row_end LIMIT 1` | 1 | 0.25 ms (0.06) |
| as of 2026, `ORDER BY row_end LIMIT 1` | 1 | 0.29 ms (0.16) |
| the current row, no `FOR SYSTEM_TIME` | | 0.25 ms (0.08) |

```sql
SELECT title, rev_id, row_start, content
FROM article FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'
WHERE page_id = 24960699
ORDER BY row_end LIMIT 1;      -- the first version that ended after the moment is the answer
```

The last line tells the server what we know. The cost of a time-travel lookup then no longer depends on how much history came after the moment: an old version is as quick to fetch as the current row. The web page uses it for every article it shows. It is only correct if no two versions of a row overlap, which `sql/90_checks.sql` verifies for our table on every build, and the experiment checks that it returns the same version as plain `AS OF` for every article at 27 moments.

With 1,007 versions the difference is 3 ms. The article on Wikipedia itself has 38,120 revisions; there it would be the difference between reading one row and reading tens of thousands.

## Backing it up

`mariadb-dump` leaves history out unless told otherwise, and says nothing about it. [scripts/backup_check.py](../scripts/backup_check.py) dumps `article` and `lab_page` both ways, restores each dump into a database of its own and compares:

```bash
python scripts/backup_check.py
```

| | current articles | versions | oldest version starts |
|---|---:|---:|---|
| the original | 30 | 13,354 | 25 February 2002 |
| restored from `mariadb-dump --dump-history` | 30 | 13,354 | 25 February 2002 |
| restored from a default `mariadb-dump` | 30 | 30 | the moment of the restore |

With `--dump-history` (MariaDB 10.11 and later) every version comes back with its own dates and text; the dump file turns `system_versioning_insert_history` on for itself. Without it, the backup holds 30 rows, and after the restore they are 30 articles that came into being a moment ago. CI runs the same comparison on all three versions.

## What we would do, and where

- **Up to a few hundred megabytes of history,** like this project: one unpartitioned table is fine. Use `ORDER BY row_end LIMIT 1` for lookups by key.
- **When most queries are about the present and the history is large:** partition by `SYSTEM_TIME`, by a time interval, with the partitions declared before any dated history is loaded.
- **When the rows are large documents:** keep the text out of the versioned row, in a table of distinct texts, and compress it.
- **When history must expire:** partitions sized to the retention period, and `DROP PARTITION`.
- **Always:** `--dump-history` in the backup command, and a restore that has been tried.
