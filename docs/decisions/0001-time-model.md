# 0001: How the revision dates are represented

- **Status:** accepted for milestone M1 (2026-11-04). Milestone M4 measures the alternatives and may change it.
- **Decided by:** Adnan S, for the team. Discuss changes in a pull request that edits this file.

## The problem

System versioning stamps a row with the time of the statement that changed it. Our rows did not change now: they changed on Wikipedia, between 2002 and 2026. If an import script replays the revisions in order, the server records the history of the import. Every version starts and ends within the few minutes the script ran, and `FOR SYSTEM_TIME AS OF '2010-06-01'` finds no rows at all.

The area brief names three ways out. We looked at four, because the first one has a variant.

## The options

**A. Replay the revisions, accept import-time stamps.** One `UPDATE` per revision, in order. Works on any MariaDB with system versioning (10.3 and later), but the system period then says when we imported each revision, so the real save time has to go into an ordinary column. "As it stood on 2010-06-01" becomes a `WHERE` on that column, which is the revision-table query that system versioning was meant to replace.

**A′. Replay with the session clock set to each save time.** `SET @@timestamp = UNIX_TIMESTAMP(rev_timestamp)` before each `UPDATE`, so the server stamps every version with the real date. This is exactly how the history would build up on a live system, one edit at a time, so it is also a fair measure of what versioning costs per edit. It needs one statement per revision, strictly in time order, and `secure_timestamp` must allow changing the session timestamp (it does by default).

**B. Write the history rows directly.** With `system_versioning_insert_history = 1` (MariaDB 10.11 and later), an `INSERT` may set `row_start` and `row_end` itself. The whole history is then one `INSERT ... SELECT`, with each version's end computed in SQL by `LEAD()` over the article's revisions. The same `secure_timestamp` condition applies.

**C. Make the revision dates an application-time period.** Add `PERIOD FOR valid_time (valid_from, valid_to)` with `UNIQUE (page_id, valid_time WITHOUT OVERLAPS)`, next to system versioning: a bitemporal table. Application time says when Wikipedia showed each text; system time says when *our* database learned it, so reloads and corrections are versioned too. But "as it stood at t" becomes a `WHERE` on the application period rather than `FOR SYSTEM_TIME`, and every revision is a current row, so the table's current data grows with every edit instead of its history.

## The decision: B

The system period holds Wikipedia's own save times, written with `system_versioning_insert_history` by [sql/02_build_history.sql](../../sql/02_build_history.sql).

Why:

- **A revision's timestamp already is a transaction time.** It is the moment Wikipedia's database committed the edit, and transaction time is what SQL:2011 calls system time. With these values, the system period says exactly what the standard means by it: this row was the current state from `row_start` to `row_end`. We rebuild the system-versioned table Wikipedia would have, had MediaWiki used one.
- **`FOR SYSTEM_TIME AS OF` then answers the time machine's question directly**, which is what the area asks for.
- **History stays history.** The current rows are the 30 current articles, and everything older is in the history, which is the part that partitioning by `SYSTEM_TIME` manages (milestone M3).
- **It is one statement**, not 13,000.

What it costs us, and how we handle it:

- **Our own import history is gone.** A reload looks the same as the first load. Option C keeps it; M4 builds C to show what that gives you.
- **The history is only as trustworthy as the loader.** Anyone allowed to use `system_versioning_insert_history` can write history with any dates. On a server with `secure_timestamp = YES`, as the docs advise for replicas, B and A′ are impossible and only A or C remain.
- **It needs MariaDB 10.11 or later.** CI tests 10.11, 11.4 and 12.3.
- **Wikipedia saves to the second, MariaDB does not accept an empty period.** Two saves of one article in the same second would give a version that starts and ends at the same instant, which MariaDB refuses (error 4112, "Incorrect system-version range"). `row_end` is also part of the primary key, so two versions may not end at the same instant either. Saves in the same second are therefore spread 1 microsecond apart, in revision-id order. The load reports how many it moved.
- **The session time zone must be UTC.** `TIMESTAMP` columns convert to and from the session time zone, and Wikipedia's times are UTC, so every script sets `time_zone = '+00:00'`.
- **"Still current" is a version-dependent date.** The server marks current rows with the largest `TIMESTAMP`: 2038-01-19 03:14:07.999999 UTC before MariaDB 11.5, and 2106-02-07 06:28:15.999999 UTC from 11.5 on 64-bit systems. Our scripts never write or compare that literal; current rows are the ones a query without `FOR SYSTEM_TIME` returns.
- **`TIMESTAMP` starts in 1970.** That is fine for Wikipedia, which started in 2001, but it is one reason this design would not fit, say, a museum's records.

## Next (milestone M4)

Build A′ and C next to B from the same `revision` table, and measure each: load time over five runs, table size, the time of an `AS OF` query, and the SQL each needs to answer "as it stood at *t*". For C, also show the question only a bitemporal table can answer: "what did our database say on day *d* about the article on day *t*?" Then revisit this decision with the numbers.
