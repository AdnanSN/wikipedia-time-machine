# 0001: How the revision dates are represented

- **Status:** accepted for milestone M1 (4 November 2026); **confirmed by measurement in milestone M4 (13 November 2026)**, with one addition: where the copy has to follow a source that changes its own past, model C is the one to use, and we built it.
- **Decided by:** Adnan S, for the team. Discuss changes in a pull request that edits this file.
- **Measured by:** [experiments/time-models/run.sql](../../experiments/time-models/run.sql); its output on our machine is [experiments/time-models/results-mariadb-12.3.3.txt](../../experiments/time-models/results-mariadb-12.3.3.txt).

## The problem

System versioning stamps a row with the time of the statement that changed it. Our rows did not change now: they changed on Wikipedia, between 2002 and 2026. If an import script replays the revisions in order, the server records the history of the import. Every version starts and ends within the few seconds the script ran, and `FOR SYSTEM_TIME AS OF '2010-06-01'` finds no rows at all.

The area brief names three ways out. We looked at four, because the first one has a variant.

## The options

**A. Replay the revisions, accept import-time stamps.** One statement per revision, in order. Works on any MariaDB with system versioning (10.3 and later), but the system period then says when we imported each revision, so the real save time has to go into an ordinary column. "As it stood on 2010-06-01" becomes a `WHERE` on that column, which is the revision-table query that system versioning was meant to replace.

**A′. Replay with the session clock set to each save time.** `SET timestamp = UNIX_TIMESTAMP(saved_at)` before each statement, so the server stamps every version with the real date. This is exactly how the history would build up on a live system, one edit at a time. It needs one statement per revision, strictly in time order, and `secure_timestamp` must allow changing the session timestamp (it does by default).

**B. Write the history rows directly.** With `system_versioning_insert_history = 1` (MariaDB 10.11 and later), an `INSERT` may set `row_start` and `row_end` itself. The whole history is then one `INSERT ... SELECT`, with each version's end computed in SQL by `LEAD()` over the article's revisions. The same `secure_timestamp` condition applies.

**C. Make the revision dates an application-time period.** `PERIOD FOR valid_time (valid_from, valid_to)` with `PRIMARY KEY (page_id, valid_time WITHOUT OVERLAPS)`, next to system versioning: a bitemporal table. Application time says when Wikipedia showed each text; system time says when *our* database learned it. "As it stood at t" becomes a `WHERE` on the application period rather than `FOR SYSTEM_TIME`, and every revision is a current row.

## The decision: B

The system period holds Wikipedia's own save times, written with `system_versioning_insert_history` by [sql/02_build_history.sql](../../sql/02_build_history.sql).

Why:

- **A revision's timestamp already is a transaction time.** It is the moment Wikipedia's database committed the edit, and transaction time is what SQL:2011 calls system time. With these values, the system period says exactly what the standard means by it: this row was the current state from `row_start` to `row_end`. We rebuild the system-versioned table Wikipedia would have, had MediaWiki used one.
- **`FOR SYSTEM_TIME AS OF` then answers the time machine's question directly**, which is what the area asks for.
- **History stays history.** The current rows are the 30 current articles, and everything older is in the history, which is the part that partitioning by `SYSTEM_TIME` manages ([docs/growth-and-partitioning.md](../growth-and-partitioning.md)).
- **It is two statements**, not 13,354.

What it costs us, and how we handle it:

- **Our own import history is gone.** A reload looks the same as the first load. Option C keeps it.
- **The history is only as trustworthy as the loader, and the server checks almost nothing** ([below](#what-each-model-lets-go-wrong)). Our own checks in [sql/90_checks.sql](../../sql/90_checks.sql) stand in for the server's.
- **It needs MariaDB 10.11 or later**, and a server that does not run with `secure_timestamp = YES`. CI tests 10.11, 11.4 and 12.3.
- **Wikipedia saves to the second, MariaDB does not accept an empty period.** Two saves of one article in the same second would give a version that starts and ends at the same instant, which MariaDB refuses (error 4112). `row_end` is also part of the primary key, so two versions may not end at the same instant either. Saves in the same second are therefore spread 1 microsecond apart, in revision-id order. The load reports how many it moved.
- **The session time zone must be UTC.** `TIMESTAMP` columns convert to and from the session time zone, and Wikipedia's times are UTC, so every script sets `time_zone = '+00:00'`.
- **"Still current" is a version-dependent date.** The server marks current rows with the largest `TIMESTAMP`: 2038-01-19 03:14:07.999999 UTC before MariaDB 11.5, and 2106-02-07 06:28:15.999999 UTC from 11.5 on 64-bit systems. Our scripts never write or compare that literal; a current row is one whose `row_end` lies after `CURRENT_TIMESTAMP`.
- **`TIMESTAMP` starts in 1970.** That is fine for Wikipedia, which started in 2001, but it is one reason this design would not fit, say, a museum's records.
- **History partitions must exist before the load.** Loaded into a table that relies on `AUTO` to create them, the history ends up in one partition and the time machine goes blank after the first live edit ([the trap](../growth-and-partitioning.md#the-trap-dated-history-and-partitions-that-do-not-exist-yet)).

## What we measured (M4)

All four models were built side by side from the same `revision` table and are checked to hold all 13,354 revisions and to name the same revision for every article at 27 moments (1 January of 2001 to 2027). A′ and B are checked to be identical row for row: same revision, same start, same end.

Setup: MariaDB 12.3.3, default configuration (128 MB buffer pool), Intel Core i5-13450HX, 16 GB RAM, NVMe SSD, Windows 11. Loads were timed 5 times each, from an empty table; queries were run once untimed and then 7 times ([experiments/harness.sql](../../experiments/harness.sql)). Medians, with the fastest and slowest run in brackets. One machine, one run of the script: the time of one load varies up to threefold between its five runs, so read the load times as "all four take seconds", not as a ranking.

### Loading

| model | statements | load time, median (fastest to slowest) | size on disk |
|---|---:|---:|---:|
| A: replay, import-time stamps | 13,354 | 6.6 s (3.6 to 10.0) | 440.8 MB |
| A′: replay, session clock set | 13,354 | 7.8 s (4.2 to 11.3) | 440.8 MB |
| B: history rows written directly | 2 | 4.9 s (4.7 to 7.1) | 223.1 MB |
| C: application-time period | 1 | 4.0 s (3.4 to 5.3) | 218.6 MB |

The replays ran inside one transaction each. With one transaction per edit, as on a live site, A′ took 36.6 s in a single run. So the direct write is not dramatically faster than a replay; writing 162 MB of text dominates all four. What differs is the result.

### What a replay leaves behind

The replayed tables hold the same rows as B in up to twice the space:

| how the table was built | size on disk | of B |
|---|---:|---:|
| B: loaded with two statements | 223.1 MB | 100% |
| A′: replayed inside one transaction | 440.8 MB | 198% |
| A′: replayed, one transaction per edit | 260.1 MB | 117% |
| the same table after `ALTER TABLE ... FORCE` (4.1 s) | 222.9 MB | 100% |

A replay puts each version where the index has room at that moment, and until its transaction commits the server cannot reuse the space of the texts it replaced. The extra size is not only disk space. One query, "all articles as of 2010, without their text", against these tables:

| table | median (fastest to slowest) | pages read from disk per run |
|---|---:|---:|
| B | 4.1 ms (3.1 to 8.8) | 0 |
| A′, replayed with one transaction per edit | 213 ms (66 to 328) | 1,290 |
| the same table after the rebuild | 4.6 ms (3.4 to 5.7) | 0 |

On the default 128 MB buffer pool, smaller than either table, the rows of the replayed table are spread over so many more pages that reading them all goes to disk on every run; B's fit in memory. A rebuild makes the two equal. `OPTIMIZE TABLE`, the usual way to ask for one, is refused on a system-versioned table until the session sets `system_versioning_alter_history = KEEP`.

This is not a property of our import. A′ with one transaction per edit is what any system-versioned table that is edited in place goes through. **A versioned table that has lived through its edits is larger and slower to scan than its row count suggests, until it is rebuilt.** It is a second reason, after the number of statements, to load a known history in one go.

### Asking

"The MariaDB article as it stood on 1 June 2010", in each model:

```sql
-- A: the system period holds the time of the import, so this is the revision-table query.
SELECT rev_id, saved_at FROM article_a FOR SYSTEM_TIME ALL
WHERE page_id = 24960699 AND saved_at <= TIMESTAMP '2010-06-01 00:00:00'
ORDER BY saved_at DESC LIMIT 1;

-- A' and B: the clause the feature exists for.
SELECT rev_id, row_start FROM article FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'
WHERE page_id = 24960699;

-- C: a WHERE on the application period. FOR SYSTEM_TIME plays no part.
SELECT rev_id, valid_from FROM article_c
WHERE page_id = 24960699 AND valid_from <= TIMESTAMP '2010-06-01 00:00:00'
                         AND valid_to   >  TIMESTAMP '2010-06-01 00:00:00';
```

| question | A | A′ | B | C |
|---|---:|---:|---:|---:|
| one article with text as of 2010 | 0.11 ms | 3.34 ms | 3.01 ms | 3.79 ms |
| the same with `ORDER BY ... LIMIT 1` | (has it) | | 0.13 ms | 0.18 ms |
| all articles as of 2010, without text | 403 ms | 295 ms | 3.5 ms | 3.6 ms |
| the current articles, without text | 390 ms | | 3.0 ms | 4.3 ms |

- **For one article, the hand-written query of model A is the fastest**, until B and C are told to stop at the first row ([why](../growth-and-partitioning.md#what-growth-does-to-as-of)); then all three are equal.
- **For all articles, B and C are equal,** and A needs a window function over every version.
- The slow numbers for A and A′ in the last two rows are the bloat of the section above, not the models themselves: those tables were measured as the replay left them.
- **C's price is not time, it is that every revision is a current row.** `SELECT * FROM article_c` returns 13,354 rows, and "the current articles" needs a `WHERE valid_to = '9999-12-31 23:59:59.999999'`. Partitioning by `SYSTEM_TIME`, which made a search of the current texts 447 times faster for B, has nothing to separate in C.

### What each model lets go wrong

Tried on made-up rows:

| attempt | result |
|---|---|
| A′ with the clock set to Wikipedia's whole seconds, two saves in one second | 2 of 3 versions kept; one is dropped without error or warning |
| B: a version overlapping another by seven months | accepted; `AS OF` then returns 2 rows for one primary key |
| B: a version whose start equals its end | refused, error 4112 |
| B without `system_versioning_insert_history` | refused, error 1906 |
| C: the same overlapping version | refused, error 1062: `WITHOUT OVERLAPS` is a constraint the server keeps |
| C: a version whose start equals its end | refused, error 4025 |

The first line is why the load spreads same-second saves by a microsecond, and why a naive replay at second resolution would be quietly incomplete. (None of our 30 articles has two saves in one second, so on this data all four models agree either way; the check that guards it runs on made-up rows.)

The second line is B's real weakness: **for history written directly, the server enforces a valid period and a unique end, and nothing else.** Overlaps and gaps are ours to prevent. In C the same mistake cannot be stored.

**On a server with `secure_timestamp = YES`** neither A′ nor B is possible. This one cannot be part of the script, because the option can only be set when the server starts; we checked it by hand on MariaDB 12.3.3, started with `--secure-timestamp=YES`:

```sql
SET timestamp = UNIX_TIMESTAMP('2016-01-01 00:00:00');
-- ERROR 1290: The MariaDB server is running with the --secure-timestamp=YES option
--             so it cannot execute this statement
SET @@session.system_versioning_insert_history = 1;     -- accepted
INSERT INTO t (id, v, row_start, row_end) VALUES (2, 2, '2001-01-01 00:00:00', '2002-01-01 00:00:00');
-- ERROR 1290, the same message
INSERT INTO c (id, valid_from, valid_to) VALUES (1, '2001-01-01', '2002-01-01');
-- accepted: an application-time period is ordinary data
```

So the setting that makes a system-versioned history tamper-proof ([who may rewrite the past](../before-and-after.md#who-may-rewrite-the-past)) also rules out loading an old one into it. A (import-time stamps) and C remain.

### What only C can answer

The other models know one time: when Wikipedia saved a text. C also knows when our copy learned it. To give that second time something to say, the experiment fills a table the way a mirror of Wikipedia would be kept: synchronised on 15 January 2026 with everything saved before 2026, synchronised again on 1 November with the 226 edits made since, and corrected on 5 November, when the 11-second vandalism of 28 November 2022 is hidden, as Wikipedia's administrators hide revisions. (The clock is set by hand at each step so that the output is repeatable.)

In an application-time table an edit is `UPDATE ... FOR PORTION OF`: "from this moment on, the article is this". The server cuts the old row short at that moment and adds a row for the rest:

```sql
UPDATE mirror FOR PORTION OF valid_time FROM '2026-05-29 12:56:58' TO '9999-12-31 23:59:59.999999'
   SET rev_id = 1356724224, editor = ..., content = ...
 WHERE page_id = 24960699;
```

Then two times fit into one question. "What did the MariaDB article say on 1 June 2026?", asked of the mirror as it stood in March and as it stands now:

```sql
SELECT rev_id, valid_from, valid_to
FROM mirror FOR SYSTEM_TIME AS OF TIMESTAMP '2026-03-01 00:00:00'     -- what our copy knew then ...
WHERE page_id = 24960699
  AND valid_from <= TIMESTAMP '2026-06-01 00:00:00'                   -- ... about that day
  AND valid_to   >  TIMESTAMP '2026-06-01 00:00:00';
```

| according to | revision | saved on Wikipedia | replaced |
|---|---:|---|---|
| the mirror as of 1 March 2026 | 1327862337 | 16 December 2025 | believed still current |
| the mirror now | 1356724224 | 29 May 2026 | 3 June 2026 |

In March the mirror could only offer the last text of 2025, believing it still current. The correction is on record the same way: as of 2 November the mirror still has the vandal's 28,258 characters, with "Bob the Builder University" in them; now it has no text for that revision. And the system period is a log of the mirror itself: 13,128 row versions written by the first synchronisation, 249 by the second, 1 by the correction.

None of this can be asked of B. A reload of B looks like the first load, and a hidden revision is simply gone, or rather cannot be hidden at all, since B's old versions are history rows that cannot be updated ([docs/before-and-after.md](../before-and-after.md#removing-one-version)).

## The decision, revisited

The brief calls the application-time period "the most interesting answer", and after building it we agree with the word. It is the semantically honest model for what this project literally is: a copy of someone else's history. The save times are facts about Wikipedia, which is what application time is for; when our database learned them is a different time, and C keeps both. It is also the only model in which the server refuses overlapping versions, the only one that can correct the past and show that it did, and it needs no special variable to load.

We keep B for the time machine, deliberately, for three reasons:

1. **The reader's question is B's question.** "What did the article say then?" is "what was the current row of Wikipedia's database then?", and B is that database's history. With B the answer is `FOR SYSTEM_TIME AS OF`, a query written for today answers for any day under `system_versioning_asof`, and a table can be joined to its own past. With C the feature this area is about would sit unused beside the query that does the work.
2. **In B, history is history.** A plain query sees 30 articles, not 13,354 versions, and the operational tools of the feature (partitions by `SYSTEM_TIME`, `DELETE HISTORY`, `--dump-history`) all apply.
3. **The two agree.** Every check that compares them passes, so choosing B costs no correctness on this data; it costs the second time dimension, which a one-off import does not have.

And we add: **when the copy has to follow its source**, a mirror that syncs, a source that hides and merges and imports, C stops being the interesting answer and becomes the right one. Section "What only C can answer" is that system in small.

A′ is what a system-versioned table does when it is the system of record, and needs no decision: there the server's clock is the true time. A is what remains on a server with `secure_timestamp = YES`, where neither A′ nor B is possible.
