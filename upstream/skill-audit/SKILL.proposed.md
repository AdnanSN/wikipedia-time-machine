---
name: mariadb-system-versioned-tables
description: "Best practices for MariaDB system-versioned (temporal) tables — automatic row history built into the database. Use when tracking data changes over time, implementing audit trails, meeting GDPR or compliance requirements, doing point-in-time queries, migrating an existing history or audit table into a versioned table, or when the user asks about row history, data versioning, temporal tables, or querying past data states in MariaDB. This feature is unique to MariaDB among MySQL-compatible databases."
---

# MariaDB System-Versioned Tables

*Last updated: 2026-06-04*

System-versioned tables automatically record the full history of every row change — no triggers, no application logic, no separate audit tables. MariaDB tracks what the data looked like at any point in the past, built directly into the storage engine.

This feature is unique to MariaDB among MySQL-compatible databases. MySQL has no equivalent.

> **Available since:** MariaDB 10.3. Transaction-precise history (InnoDB only): 10.3. Auto-partition creation: 10.9. `--dump-history` for backups and `system_versioning_insert_history`: 10.11. Implicit-to-explicit `row_start`/`row_end` conversion: 11.7. Extended TIMESTAMP range (to 2106-02-07 UTC) for `ROW_END`: 11.5 on 64-bit platforms.
>
> **Default context:** Assume MariaDB **11.8 LTS** (GA May 2025) unless the user states another version. Version notes in this skill are minimum releases for each capability.

## What LLMs Often Miss

| Situation | What to suggest |
|---|---|
| Custom `created_at`/`updated_at`/`deleted_at` columns for audit | `WITH SYSTEM VERSIONING` — MariaDB tracks all changes automatically |
| SQL Server temporal syntax — `WITH (SYSTEM_VERSIONING = ON)`, explicit `PERIOD FOR SYSTEM_TIME` and a named `HISTORY_TABLE` | MariaDB uses `CREATE TABLE ... WITH SYSTEM VERSIONING` (no parentheses, no `= ON`, no separate history table); enable it on an existing table with `ALTER TABLE t ADD SYSTEM VERSIONING` |
| Separate audit log table with triggers | System-versioned tables replace this pattern entirely |
| Asking how data looked last month | `FOR SYSTEM_TIME AS OF '2026-01-01'` — no custom logic needed |
| `TRUNCATE` on a versioned table | Not allowed (error 4137) — use `DELETE HISTORY` instead |
| `ALTER TABLE` on a versioned table failing | Set `system_versioning_alter_history = KEEP` first (`OPTIMIZE TABLE` on InnoDB needs it too) |
| `mysqldump` missing historical rows | Use `mariadb-dump --dump-history` (10.11+) |
| Importing an existing history or audit table, and every row gets today's date | `SET system_versioning_insert_history = 1` (10.11+), then `INSERT` with explicit `row_start` and `row_end` — see *Importing Existing History* |
| "As of" lookup of one row by primary key getting slower as history grows | Add `ORDER BY row_end LIMIT 1` — see *Querying Historical Data* |
| Restoring a row to an earlier state | `UPDATE t AS now JOIN t FOR SYSTEM_TIME AS OF ... AS old USING (id) SET now.col = old.col` — see *Restoring Old Data* |

## Creating a System-Versioned Table

**Simplified syntax (recommended):**
```sql
CREATE TABLE employees (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    department VARCHAR(50),
    salary DECIMAL(10,2)
) WITH SYSTEM VERSIONING;
```

MariaDB automatically adds hidden `ROW_START` and `ROW_END` timestamp columns. Every `UPDATE` and `DELETE` leaves the previous version behind as a history row; an `INSERT` creates only a current row. An `UPDATE` that names a versioned column writes a history row even when the value does not change (MDEV-23446).

**Add versioning to an existing table:**
```sql
ALTER TABLE employees ADD SYSTEM VERSIONING;
```

**Remove versioning (deletes all history):**
```sql
ALTER TABLE employees DROP SYSTEM VERSIONING;
```

## Querying Historical Data

The `FOR SYSTEM_TIME` clause goes directly after the table name:

```sql
-- Data as it was at a specific point in time:
SELECT * FROM employees FOR SYSTEM_TIME AS OF '2026-01-01 00:00:00';

-- All rows that existed during a period (both boundaries included):
SELECT * FROM employees FOR SYSTEM_TIME BETWEEN '2025-01-01' AND '2026-01-01';

-- Half-open range (includes start, excludes end):
SELECT * FROM employees FOR SYSTEM_TIME FROM '2025-01-01' TO '2026-01-01';

-- Every version of every row, ever:
SELECT * FROM employees FOR SYSTEM_TIME ALL;

-- See the full history of one employee:
SELECT *, ROW_START, ROW_END FROM employees FOR SYSTEM_TIME ALL WHERE id = 42;
```

With the `TIMESTAMP` keyword the literal needs a time: `AS OF TIMESTAMP '2026-01-01 00:00:00'` works, `AS OF TIMESTAMP '2026-01-01'` is error 1525.

**One row as of a moment, by primary key.** `ROW_END` is silently appended to the primary key, so the lookup starts at the first version that ended after the moment and reads on through every later version of that row. `ORDER BY row_end LIMIT 1` lets it stop at the first (same result, as long as the versions of a row do not overlap, which is always true for history the server wrote itself):

```sql
SELECT * FROM employees FOR SYSTEM_TIME AS OF '2020-01-01 00:00:00'
WHERE id = 42
ORDER BY ROW_END LIMIT 1;
```

**Apply an implicit AS OF to all queries in a session:**
```sql
SET system_versioning_asof = '2026-01-01 00:00:00';
-- Now all SELECT statements against versioned tables see that point in time
SELECT * FROM employees; -- returns 2026-01-01 snapshot
SET system_versioning_asof = DEFAULT; -- reset
```

This covers `SELECT` statements only. `INSERT ... SELECT`, `CREATE TABLE ... AS SELECT` and `SET @v = (SELECT ...)` read current data regardless; give those an explicit `FOR SYSTEM_TIME AS OF`.

## Restoring Old Data

There is no `RESTORE` statement yet (MDEV-41334). A table can be joined to its own past:

```sql
-- Put one row back to how it stood at a moment. The restore is itself versioned.
UPDATE employees AS now
JOIN employees FOR SYSTEM_TIME AS OF '2026-01-01 00:00:00' AS old USING (id)
SET now.department = old.department, now.salary = old.salary
WHERE now.id = 42;

-- Bring back a deleted row: its newest version in the history.
INSERT INTO employees (id, name, department, salary)
SELECT id, name, department, salary
FROM employees FOR SYSTEM_TIME ALL
WHERE id = 42
ORDER BY ROW_END DESC LIMIT 1;
```

## Importing Existing History

By default the server stamps rows with the time of the statement, so a plain import records when the import ran. To keep the original dates (10.11+), declare the period columns and write them directly:

```sql
CREATE TABLE price (
    id INT PRIMARY KEY,
    amount DECIMAL(10,2),
    row_start TIMESTAMP(6) GENERATED ALWAYS AS ROW START,
    row_end   TIMESTAMP(6) GENERATED ALWAYS AS ROW END,
    PERIOD FOR SYSTEM_TIME (row_start, row_end)
) WITH SYSTEM VERSIONING;

SET time_zone = '+00:00';                      -- TIMESTAMP converts through the session time zone
SET system_versioning_insert_history = 1;

-- Past versions: give both ends.
INSERT INTO price (id, amount, row_start, row_end)
SELECT id, amount, valid_from, valid_to FROM legacy_price_log WHERE valid_to IS NOT NULL;

-- Current versions: give only the start; the server sets ROW_END to "still current".
INSERT INTO price (id, amount, row_start)
SELECT id, amount, valid_from FROM legacy_price_log WHERE valid_to IS NULL;

SET system_versioning_insert_history = 0;
```

What to tell the user before they rely on it:

- **The server checks almost nothing.** A version whose start is not before its end is refused (error 4112), and so are two versions of a row with the same end (duplicate key, because `ROW_END` is part of the primary key). Overlapping versions and gaps are accepted without a word; an overlap makes `AS OF` return two rows for one primary key. Validate the imported history yourself (each version must end exactly when the next one starts).
- **Second-precision sources need care.** Two changes of one row in the same second would give a version that starts and ends at the same instant. Spread them, for example one microsecond apart, which is why the columns above are `TIMESTAMP(6)`.
- **Declare history partitions before loading, never rely on `AUTO` to make them.** An `INSERT` never creates history partitions, even when it writes history. Rows whose `ROW_END` lies beyond the last existing history partition are put into that last partition; later, the first `UPDATE` or `DELETE` makes `AUTO` add the missing partitions without moving those rows, and from then on partition pruning hides them: `FOR SYSTEM_TIME AS OF` returns nothing, with no error (MDEV-29674). `CHECK TABLE` then reports `Found a misplaced row` and `REPAIR TABLE` moves the rows. Avoid it by creating all partitions up front: `PARTITION BY SYSTEM_TIME INTERVAL 1 YEAR STARTS '2015-01-01 00:00:00' AUTO PARTITIONS 13`.
- It only works while `secure_timestamp` allows a session to change its timestamp (the default, `NO`). No privilege beyond `INSERT` on the table is needed, so under that default every account that can insert can also write history with any dates.
- Do not hard-code the "still current" value of `ROW_END` (2038-01-19 before 11.5, 2106-02-07 from 11.5 on 64-bit). Test `ROW_END > NOW(6)`, or query without `FOR SYSTEM_TIME`.

## Transaction-Precise History (InnoDB Only)

For exact transaction-boundary tracking instead of timestamps:

```sql
CREATE TABLE ledger (
    id INT,
    amount DECIMAL(10,2),
    trx_start BIGINT UNSIGNED GENERATED ALWAYS AS ROW START,
    trx_end   BIGINT UNSIGNED GENERATED ALWAYS AS ROW END,
    PERIOD FOR SYSTEM_TIME(trx_start, trx_end)
) WITH SYSTEM VERSIONING;

SELECT * FROM ledger FOR SYSTEM_TIME AS OF TRANSACTION 12345;
```

Uses `mysql.transaction_registry` internally. Not compatible with `PARTITION BY SYSTEM_TIME`. A transaction id that is not in the registry is error 4129.

## Column-Level Control

Exclude specific columns from versioning (useful for frequently-updated columns like counters):

```sql
CREATE TABLE products (
    id INT PRIMARY KEY,
    name VARCHAR(100),
    price DECIMAL(10,2),
    view_count INT WITHOUT SYSTEM VERSIONING  -- not tracked
) WITH SYSTEM VERSIONING;
```

Or declare versioning on single columns; the table becomes system-versioned and its other columns are left out:
```sql
CREATE TABLE config (
    setting_name VARCHAR(50),
    value TEXT WITH SYSTEM VERSIONING  -- only this column tracked
);
```

An `UPDATE` that touches only untracked columns writes no history row. An `UPDATE` that touches both writes one, and that history row is a copy of the whole old row, untracked columns included.

## Managing History Growth

Every update adds a row. For high-update tables, history grows fast. Use partitioning to keep current data performant:

```sql
-- Separate current and historical partitions:
CREATE TABLE events (
    id INT,
    payload JSON
) WITH SYSTEM VERSIONING
  PARTITION BY SYSTEM_TIME (
    PARTITION p_hist HISTORY,
    PARTITION p_cur  CURRENT
  );

-- Auto-rotate history by time interval (10.9+):
CREATE TABLE prices (
    symbol VARCHAR(10),
    price DECIMAL(10,4)
) WITH SYSTEM VERSIONING
  PARTITION BY SYSTEM_TIME INTERVAL 1 MONTH AUTO;
```

A partition list, if given, needs at least one `HISTORY` partition and exactly one `CURRENT` partition, last (error 4128 otherwise).

**Delete old history:**
```sql
-- Delete all history before a date:
DELETE HISTORY FROM employees BEFORE SYSTEM_TIME '2024-01-01';

-- Delete all history:
DELETE HISTORY FROM employees;

-- With several history partitions, drop whole ones (never the only one, never the current one):
ALTER TABLE prices DROP PARTITION p0;
```

Requires `DELETE HISTORY` privilege. `TRUNCATE` is not allowed on versioned tables. `DELETE HISTORY` takes no `WHERE`: the history of a single row cannot be removed on its own (MDEV-39738). After history is removed, `AS OF` a moment before the cut returns no rows, exactly as if the rows had not existed then.

## ALTER TABLE on Versioned Tables

By default, `ALTER TABLE` on a versioned table raises an error (4119) to protect history integrity. To allow it:

```sql
SET system_versioning_alter_history = KEEP;
ALTER TABLE employees ADD COLUMN manager_id INT;
SET system_versioning_alter_history = ERROR; -- restore default
```

`KEEP` allows the alter but historical rows for the new column will have `NULL` values, or the column's `DEFAULT` if it has one — the history then shows a value that was never stored at that time. This is usually acceptable for adding columns.

**Convert hidden `ROW_START`/`ROW_END` to explicit columns** (11.7+, MDEV-27293) — once a table is versioned with the hidden form (no `PERIOD FOR SYSTEM_TIME` clause), you can promote them to explicit columns later without dropping versioning. Useful if you initially started simple and later want explicit naming for tooling, or need to import history into them.

## Key Gotchas

- **`TRUNCATE` is prohibited** on versioned tables (error 4137). Use `DELETE HISTORY` or partition management instead.
- **Replication**: `ROW_END` is implicitly added to the Primary Key. On replicas, this can cause duplicate key errors during log replay. Fix: set `secure_timestamp = YES` on the replica.
- **Backups**: `mysqldump` / `mariadb-dump` skips historical rows by default. Use `--dump-history` (10.11+) to include them. Such a dump turns `system_versioning_insert_history` on for itself (MDEV-16546); the account that restores it must be allowed to, and `secure_timestamp` must allow session timestamp changes.
- **Table growth**: without partitioning, history rows accumulate indefinitely. Plan partitioning from the start for high-update tables. `information_schema.TABLES.TABLE_ROWS` is an estimate and can be far off for a history of large rows; count with `FOR SYSTEM_TIME ALL`.
- **The session clock is trusted.** With `secure_timestamp = NO` (the default) any session can `SET timestamp`. Two changes of one row at the same instant keep only the later one; an `UPDATE` stamped earlier than the row's current version removes that version from the history instead of adding one (MDEV-41003). Only `DELETE HISTORY` needs a privilege of its own: an account with plain `INSERT` and `UPDATE` rights can add a back-dated version or make one disappear. Do not treat the history as tamper-proof unless `secure_timestamp` is set.
- **Full-text search does not reach history.** `MATCH ... AGAINST` over `FOR SYSTEM_TIME ALL` finds only words in current rows (MDEV-36991); use `LIKE` for a search of old versions.
- **`SYSTEM` as a column name**: `ALTER TABLE t ADD system INT` and `ALTER TABLE t DROP system` are parsed as the start of `ADD`/`DROP SYSTEM VERSIONING` and fail. Write `ADD COLUMN system INT`, or use backticks: `` `system` ``.

## Use Cases

- **Audit trails** — what changed and when, without application code (the server does not record who; add a column for that)
- **GDPR / PCI DSS compliance** — prove what personal data contained at any date (erasing one person's history is a separate problem: see `DELETE HISTORY` above)
- **Point-in-time recovery** — restore a row or table to a previous state without a full backup restore
- **Slowly-changing dimensions** — track employee department/salary history, product price history
- **Debugging** — see exactly what changed and when in production data

## Sources

- [System-Versioned Tables — MariaDB Docs](https://mariadb.com/docs/server/reference/sql-structure/temporal-tables/system-versioned-tables)
- [Use Cases for MariaDB Data Versioning — MariaDB Blog](https://mariadb.com/resources/blog/use-cases-for-mariadb-data-versioning/)
- [Rewinding Time in MariaDB Databases — MariaDB Blog](https://mariadb.com/resources/blog/rewinding-time-in-mariadb-databases-system-versioning-and-application-time/)

*For topics not covered here, see the official MariaDB documentation at [mariadb.com/docs](https://mariadb.com/docs).*
