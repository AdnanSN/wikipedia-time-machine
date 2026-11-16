# What this project found for MariaDB

Building the time machine meant using system-versioned tables harder than their documentation does: 13,354 real versions, dated in the past, partitioned, replayed, backed up, edited. Three things came out of that which are of use beyond this repository. Each one is a script here that anyone can run, and each is written up so that it can be handed to MariaDB as it is.

> **Status, 13 November 2026:** all three are prepared in this folder and **not yet submitted**. When one is, its link goes into the last column below, in the same pull request.

| # | What | For whom | Evidence | Submitted |
|---|------|----------|----------|-----------|
| 1 | `FOR SYSTEM_TIME AS OF` silently returns no rows after dated history is loaded into an `AUTO`-partitioned table | [MDEV-29674](https://jira.mariadb.org/browse/MDEV-29674) (stalled since 2022) | [mdev-29674-wrong-results.sql](mdev-29674-wrong-results.sql) | not yet |
| 2 | MariaDB's own briefing for AI coding agents has four examples that do not run and three claims that are wrong or out of date | [github.com/MariaDB/skills](https://github.com/MariaDB/skills) | [skill-audit/](skill-audit/) | not yet |
| 3 | Notes on the documentation page | [System-Versioned Tables](https://mariadb.com/docs/server/reference/sql-structure/temporal-tables/system-versioned-tables) | below | not yet |

All of it was observed on **MariaDB 12.3.3** (Windows 11, x64). CI runs the two scripts on 10.11, 11.4 and 12.3 and keeps their output as an artifact of every run; the audit's five checks must hold on all three, and the bug reproduction is recorded without being judged, so a fix will show up as a changed output rather than a failed build.

## 1. A time machine that goes blank after its first edit

**In one sentence:** load history with `system_versioning_insert_history` into a table created with `PARTITION BY SYSTEM_TIME INTERVAL ... AUTO`, make one ordinary `UPDATE`, and from then on `FOR SYSTEM_TIME AS OF` returns nothing for the loaded history, with no error and no warning.

We ran into it because it is what the documentation suggests for our case: yearly partitions, created automatically, for a history that starts in 2002. The load is correct and every check passes. The table breaks later, on the first live edit.

Reduced to two rows ([the whole script](mdev-29674-wrong-results.sql), [its output on 12.3.3](mdev-29674-results-mariadb-12.3.3.txt)):

```sql
CREATE TABLE t (
  id INT PRIMARY KEY, v VARCHAR(20),
  row_start TIMESTAMP(6) GENERATED ALWAYS AS ROW START,
  row_end   TIMESTAMP(6) GENERATED ALWAYS AS ROW END,
  PERIOD FOR SYSTEM_TIME (row_start, row_end)
) WITH SYSTEM VERSIONING
  PARTITION BY SYSTEM_TIME INTERVAL 1 YEAR STARTS '2020-01-01 00:00:00' AUTO;

SET @@session.system_versioning_insert_history = 1;
INSERT INTO t (id, v, row_start, row_end) VALUES (1, 'as of 2022', '2021-06-01 00:00:00', '2023-06-01 00:00:00');
INSERT INTO t (id, v, row_start)          VALUES (1, 'current',    '2023-06-01 00:00:00');
SET @@session.system_versioning_insert_history = 0;

SELECT v FROM t FOR SYSTEM_TIME AS OF TIMESTAMP '2022-07-01 00:00:00';   -- 'as of 2022': right
CHECK TABLE t;                                                            -- OK

UPDATE t SET v = 'edited today' WHERE id = 1;                             -- one ordinary edit

SELECT v FROM t FOR SYSTEM_TIME AS OF TIMESTAMP '2022-07-01 00:00:00';   -- no rows: wrong
CHECK TABLE t;                                                            -- Found a misplaced row
REPAIR TABLE t;                                                           -- Moved 1 misplaced rows
SELECT v FROM t FOR SYSTEM_TIME AS OF TIMESTAMP '2022-07-01 00:00:00';   -- 'as of 2022' again
```

**Why it happens.**

1. An `INSERT` never creates history partitions, not even one that writes history. After `CREATE TABLE` there is one history partition, for 2020. The row that ended in 2023 is put into it, because the last history partition takes whatever lies beyond it. That state is legal, so queries are right and `CHECK TABLE` says OK.
2. The `UPDATE` needs a history partition for the current year. `AUTO` creates all the missing years at once, and by design it never moves rows that are already there.
3. The partition for 2020 is now no longer the last one, but it still holds a row that ended in 2023. Partition pruning trusts the layout and skips it for any moment after 2020 (`EXPLAIN PARTITIONS` shows `p2,p3,p4,p5,p6,pn`). `FOR SYSTEM_TIME ALL` still finds the row.

**What it adds to MDEV-29674.** That report shows the row going into the wrong partition and asks whether that should be "a warning, an error, or nothing", and notes that the main user, `mariadb-dump`, is not affected because a dump recreates the partitions. Two things are new here:

- the consequence is **wrong query results**, silently, which the report and its comments do not mention (they show `CHECK TABLE` complaining);
- the affected user is not a restore but a **migration**: bringing an existing history into a new versioned table, which is what `system_versioning_insert_history` is for, and which nothing in the documentation warns against combining with `AUTO`. The failure is delayed until the first edit, after every acceptance test has passed.

Related, and different: [MDEV-25529](https://jira.mariadb.org/browse/MDEV-25529) (in testing for 13.2) is about `ALTER TABLE ... PARTITION BY SYSTEM_TIME INTERVAL ... AUTO` leaving the history a table already has in one partition. The path here is an `INSERT` under `system_versioning_insert_history` into a table that is already partitioned.

On the full data set it is the same: 13,324 history rows in the partition for 2002, 27 articles as of June 2010 before the first `UPDATE` and 0 after it, `REPAIR TABLE` reporting `Moved 13312 misplaced rows` ([experiments/growth/run.sql](../experiments/growth/run.sql), part 4).

**What avoids it,** all three checked in that experiment:

- declare the history partitions before loading (`... STARTS '2002-01-01 00:00:00' AUTO PARTITIONS 26`): the same `INSERT` then places each row by its `row_end`. This is what the project does;
- or add them by hand afterwards (`ALTER TABLE ... ADD PARTITION (PARTITION p2003 HISTORY)`), which does move the rows that belong after the last partition;
- or run `REPAIR TABLE` after the first statement that made `AUTO` act.

**What we would suggest to MariaDB:** when an `INSERT` under `system_versioning_insert_history` writes a row whose `row_end` lies beyond the last history partition of an `INTERVAL` table, raise warning 4114 (`last HISTORY partition is out of INTERVAL, need more HISTORY partitions`), as an `UPDATE` in the same situation already does; and a sentence in the documentation of `system_versioning_insert_history` saying that history partitions must exist before history is loaded.

*To submit:* as a comment on MDEV-29674 with the script attached, or as a new issue linked to it. The text above is written to be pasted.

## 2. MariaDB's agent skill, tested line by line

MariaDB publishes short briefings that AI coding agents read before they write MariaDB code ([github.com/MariaDB/skills](https://github.com/MariaDB/skills), MIT licence, "contributions and feedback welcome via pull requests"). One of the eight is about system-versioned tables. An agent that follows it writes what it shows, so every example in it has to run.

[skill-audit/run.sql](skill-audit/run.sql) runs each example and tests each claim that can be tested on one server, against the briefing as of commit `f5016dc` (4 June 2026; the audited copy is [skill-audit/SKILL.audited.md](skill-audit/SKILL.audited.md)). Of 32 items, 22 hold. The other ten ([full output](skill-audit/results-mariadb-12.3.3.txt)):

| In the skill | On a real server | |
|---|---|---|
| "Every `INSERT`, `UPDATE`, and `DELETE` creates a history row." | Two `INSERT`s: 0 history rows. An `UPDATE`: 1. A `DELETE`: 1. | wrong |
| `CREATE TABLE config (key VARCHAR(50), value TEXT WITH SYSTEM VERSIONING)` | Error 1064: `key` is a reserved word | fails as written |
| `PARTITION BY SYSTEM_TIME INTERVAL 1 MONTH AUTO (PARTITION p_cur CURRENT)` | Error 4128: a partition list needs at least one `HISTORY` partition | fails as written |
| "Delete all history": `ALTER TABLE employees DROP PARTITION p_hist` | Error 1505: `employees` is not partitioned | fails as written |
| The same on the skill's `events` table, which has `p_hist` | Error 4128: the only history partition cannot be dropped | fails as written |
| Deleting all history "requires DROP SYSTEM VERSIONING + re-add, or partition drop" | `DELETE HISTORY FROM events` does it: 1 history row before, 0 after | wrong |
| `DELETE HISTORY` with a future timestamp "can accidentally delete active rows (MDEV-25468)" | `BEFORE SYSTEM_TIME '2200-01-01'` leaves both current rows. MDEV-25468 was fixed in 10.3.29, 10.4.19 and 10.5.10 | out of date |
| (missing) | `AS OF TIMESTAMP '2026-01-01'`, a date without a time, is error 1525, though the skill's own string literals work | worth adding |
| (missing) | After `ADD COLUMN ... NOT NULL DEFAULT 7` under `KEEP`, every old version shows 7 | worth adding |
| "`SYSTEM` as a column name: causes parser errors in `ALTER TABLE`" | Only in the short form `ADD system INT`. `ADD COLUMN system INT` is accepted without backticks | worth adding |

[skill-audit/SKILL.proposed.md](skill-audit/SKILL.proposed.md) is the briefing with those corrected and with what this project learned added, every addition tested in this repository:

- a section **Importing Existing History** (the two-`INSERT` pattern, what the server does and does not check, same-second sources, and the partition trap of section 1);
- **Restoring Old Data**: a row joined to its own past, and undeleting from the history;
- `ORDER BY row_end LIMIT 1` for a lookup by key (990 rows read become 1; [experiments/growth](../experiments/growth/run.sql), part 6);
- that `system_versioning_asof` covers `SELECT` statements only;
- that `OPTIMIZE TABLE` is refused like any `ALTER`, that a full-text index does not reach history (MDEV-36991), that one row's history cannot be deleted (MDEV-39738), and that under the default `secure_timestamp = NO` an account with plain `INSERT` and `UPDATE` rights can add a back-dated version or make one disappear (MDEV-41003).

To see exactly what changed:

```bash
git diff --no-index upstream/skill-audit/SKILL.audited.md upstream/skill-audit/SKILL.proposed.md
```

*To submit:* a pull request to MariaDB/skills that replaces `mariadb-system-versioned-tables/SKILL.md` with the proposed file, with the table above as its description and a link to the audit script.

## 3. Notes on the documentation page

Small things on [System-Versioned Tables](https://mariadb.com/docs/server/reference/sql-structure/temporal-tables/system-versioned-tables), as read on 12 November 2026:

- **Two sentences contradict each other** under *Removing Old History*: "The TRUNCATE TABLE statement drops all historical records from a system-versioned table." is followed directly by "Historic data is protected from TRUNCATE statements ... an Error 4137 is instead raised". The second is what the server does.
- **`system_versioning_insert_history` has one line.** What we had to find out by trying, and what [docs/decisions/0001-time-model.md](../docs/decisions/0001-time-model.md) now records: a row given only `row_start` becomes a current row; an empty or negative period is error 4112; overlapping periods and gaps are accepted; it needs no privilege beyond `INSERT`; history partitions must exist first (section 1).
- **Three behaviours for a version that starts and ends at the same instant.** The page's own example shows a row with `row_start = row_end`, produced by an `INSERT` and a `DELETE` at the same `@@timestamp`. An `UPDATE` in the same situation stores no such row, and the version is lost without notice; a direct insert of such a row is refused (4112). A sentence saying which of these is intended would help anyone replaying changes at second resolution.
- **`system_versioning_asof`** is described as having "no effect on DML". It also has none on `SET @v = (SELECT ...)` and `CREATE TABLE ... AS SELECT`, which are easy to take for reads.
- **`OPTIMIZE TABLE`** on an InnoDB versioned table fails with "Not allowed for system-versioned ... Change @@system_versioning_alter_history", which the page's section on that variable does not mention.
- **`UPDATE t FOR SYSTEM_TIME ALL SET ...`** answers with error 1099, "Table 't' was locked with a READ lock and can't be updated". A message saying that history rows cannot be updated would be clearer.
