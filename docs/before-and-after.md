# Before and after: what history in the database replaces, and where it stops being the right answer

Milestone M5. Everything on this page comes from one script, [experiments/before-after/run.sql](../experiments/before-after/run.sql), and its output on our machine, [experiments/before-after/results-mariadb-12.3.3.txt](../experiments/before-after/results-mariadb-12.3.3.txt). Run it yourself with:

```bash
python scripts/run_sql.py experiments/before-after/run.sql
```

## The short answers

- **It replaces a second table, two triggers and a rule nobody can enforce.** Kept by triggers, as you would on MySQL or PostgreSQL, the same history needs a history table and 691 characters of trigger code that must be rewritten with every new column. Kept by the application, as Wikipedia does, it needs every piece of code that edits to also write a revision row. Kept by the server, it needs three words at the end of the table definition.
- **It costs nothing we could measure.** An edit of a 57 kB article took about a millisecond in all three designs and in a table that keeps no history at all.
- **It catches what triggers miss.** A cascading delete removed two rows: the trigger recorded none of them, the versioned table kept both. `TRUNCATE` emptied the trigger table without a trace and was refused on the versioned one.
- **It stops being the right answer** when one version must be removed or changed, when the history must be proof against the people who can write to the table, when you need to know who and not only when, and when the rows are large documents that change a little at a time. Each of these is tested below, with what to do instead.

## Method

- **Machine and server:** as for the other experiments: Intel Core i5-13450HX, 16 GB RAM, NVMe SSD, Windows 11, MariaDB 12.3.3 with its default configuration (128 MB buffer pool, `innodb_flush_log_at_trx_commit = 1`, so every commit is written to disk).
- **The three designs** hold the same 13,354 versions and are checked to give the same answer for every article at 27 moments.
- **Reading** is timed as in the other experiments: prepared once, one untimed run, 7 timed runs, median reported.
- **Editing** is timed as a batch: the last 200 edits of the MariaDB article (56,705 bytes of text each on average) are made again in each design, one transaction per edit, 5 times over. The time of a batch divided by 200 is the time of an edit.
- **Behaviour** (what is refused, what is recorded) is tried on small tables and written into a `finding` table as the server answered. Seven of the findings are also checked: the script stops with an error if, say, the versioned table ever accepts a `TRUNCATE`.
- **Limits:** one machine, one data set, single-user. The edit timings have a spread between runs as large as the differences between designs; we report it instead of ranking them. Run the script as an account that may create users: one test borrows the rights of a locked, throwaway account.

## Three ways to keep a history

**The application's way** is Wikipedia's: a `page` row per article and a `revision` row per edit ([sql/01_schema.sql](../sql/01_schema.sql)). The database stores what it is given. The application must write the revision row on every edit, in the same transaction as the change.

**The trigger way** is what MySQL and PostgreSQL offer, neither of which has system versioning. A table for the current rows, a second one for the old rows, and triggers that copy a row across before it changes or disappears:

```sql
CREATE TABLE trig_article (page_id INT UNSIGNED NOT NULL PRIMARY KEY, title ..., content MEDIUMTEXT NULL,
                           valid_from TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6));
CREATE TABLE trig_history (page_id INT UNSIGNED NOT NULL, title ..., content MEDIUMTEXT NULL,
                           valid_from TIMESTAMP(6) NOT NULL, valid_to TIMESTAMP(6) NOT NULL,
                           PRIMARY KEY (page_id, valid_to));

CREATE TRIGGER trig_article_before_update BEFORE UPDATE ON trig_article FOR EACH ROW
BEGIN
  INSERT INTO trig_history (page_id, title, rev_id, editor, summary, minor_edit, len, sha1, tags,
                            content, valid_from, valid_to)
  VALUES (OLD.page_id, OLD.title, OLD.rev_id, OLD.editor, OLD.summary, OLD.minor_edit, OLD.len,
          OLD.sha1, OLD.tags, OLD.content, OLD.valid_from, NOW(6));
  SET NEW.valid_from = NOW(6);
END;
-- ... and the same INSERT again in a BEFORE DELETE trigger.
```

**The server's way:**

```sql
CREATE TABLE article ( ... ) WITH SYSTEM VERSIONING;
```

| | tables | triggers | trigger code | kept complete by |
|---|---:|---:|---:|---|
| application (revision table) | 2 | 0 | 0 | every statement that edits also inserting a revision |
| triggers | 2 | 2 | 691 characters | two triggers, rewritten whenever a column is added |
| system versioning | 1 | 0 | 0 | the server |

### The same question, three ways

"The MariaDB article as it stood on 1 June 2010." All three return revision 365034244.

```sql
-- The application's way: sort the article's revisions, take the newest before the moment.
SELECT r.rev_id, r.rev_timestamp
FROM page AS p JOIN revision AS r ON r.rev_page = p.page_id
WHERE p.page_title = 'MariaDB' AND r.rev_timestamp <= '2010-06-01 00:00:00'
ORDER BY r.rev_timestamp DESC, r.rev_id DESC
LIMIT 1;

-- The trigger way: the answer may be in either table, so ask both.
SELECT rev_id, valid_from
FROM (SELECT title, rev_id, valid_from, NULL AS valid_to FROM trig_article
      UNION ALL
      SELECT title, rev_id, valid_from, valid_to FROM trig_history) AS both_tables
WHERE title = 'MariaDB' AND valid_from <= '2010-06-01 00:00:00'
  AND (valid_to > '2010-06-01 00:00:00' OR valid_to IS NULL);

-- The server's way.
SELECT rev_id, row_start
FROM article FOR SYSTEM_TIME AS OF TIMESTAMP '2010-06-01 00:00:00'
WHERE title = 'MariaDB';
```

For one article the three are of similar length. They part ways with the next question, "every article as it stood that day": one clause for the server, the same `UNION` for the triggers, and a window function over every revision for the revision table.

## What it costs

| | application | triggers | system versioning | no history at all |
|---|---:|---:|---:|---:|
| one edit of a 57 kB article (median of 5 batches of 200) | 0.79 ms | 1.20 ms | 1.06 ms | 0.94 ms |
| fastest and slowest batch, per edit | 0.69 to 1.20 | 0.95 to 1.66 | 0.95 to 1.46 | 0.84 to 1.21 |
| one article with text as of 2010 | 0.08 ms | 9.02 ms | 0.08 ms | |
| every article as of 2010, without text | 5.24 ms | 3.22 ms | 3.67 ms | |
| size on disk | 231.0 MB | 220.1 MB | 221.1 MB | |

- **Keeping the history is free at this scale.** The table that keeps none is not faster than the three that do; the spread between batches of the same design is as large as the differences between designs. An edit is dominated by writing 57 kB and committing it, and all four do that once.
- **Reading one old version** is as fast with `FOR SYSTEM_TIME` (with [the `LIMIT` shortcut](growth-and-partitioning.md#what-growth-does-to-as-of)) as with the hand-written revision query. The natural `UNION` over the trigger tables is a hundred times slower, because the server builds the union before it filters; it can be rewritten by hand to be fast, which is one more thing to write.
- **The size is the same** in all three. System versioning does not store history more cheaply; it stores the same rows.

So the case for system versioning is not speed or size. It is that the history cannot be forgotten and need not be written.

## What triggers miss

Each line is the same action on a table with a history trigger and on a system-versioned table:

| action | trigger history | system versioning |
|---|---|---|
| a parent row is deleted and a foreign key cascades to 2 child rows | **0 of 2** recorded: cascades do not run triggers | both kept |
| `TRUNCATE TABLE` | accepted; table empty, nothing recorded | refused, error 4137 |
| `UPDATE` of a row in the history itself | accepted; the history now reads "it never said that" | 0 rows changed: history rows cannot be addressed |
| `DROP TRIGGER`, then an edit | the edit is not recorded, and nothing says so | not applicable |

The cascade is the instructive one, because nothing went wrong. Nobody disabled anything; a foreign key did what it was declared to do, and the audit trail has a hole. A trigger records the statements that reach it. The server records what happened to the rows.

## Where system versioning stops being the right answer

### Removing one version

Wikipedia's administrators hide single revisions: libel, personal data, copyright. Data protection law asks the same of anyone who stores personal data. System versioning offers `DELETE HISTORY`, for everything before a moment or for everything, and nothing finer:

| attempt | result |
|---|---|
| `DELETE HISTORY FROM t WHERE ...` | error 1064: there is no `WHERE` (requested as [MDEV-39738](https://jira.mariadb.org/browse/MDEV-39738)) |
| `UPDATE t FOR SYSTEM_TIME ALL SET ...` | error 1099, "locked with a READ lock" |
| an ordinary `UPDATE` or `DELETE` whose `WHERE` matches a history row | accepted, 0 rows changed |

What does work is to keep the sensitive column out of the versioning and a versioned flag beside it, with one subtlety that we only found by testing:

```sql
CREATE TABLE redactable (
  rev_id  INT UNSIGNED NOT NULL PRIMARY KEY,
  hidden  BOOLEAN NOT NULL DEFAULT FALSE,
  content MEDIUMTEXT NULL WITHOUT SYSTEM VERSIONING
) WITH SYSTEM VERSIONING;

-- Wrong: one statement. The flag is versioned, so a history row is written,
-- and a history row is a copy of the whole old row, text included.
UPDATE redactable SET hidden = TRUE, content = NULL WHERE rev_id = 1;

-- Right: the text first, alone. An UPDATE of an unversioned column writes no history
-- row, so the text is simply gone. Then the flag, whose history row has nothing to leak.
UPDATE redactable SET content = NULL WHERE rev_id = 2;
UPDATE redactable SET hidden = TRUE WHERE rev_id = 2;
```

After the one-statement version, `FOR SYSTEM_TIME ALL` still returns the libellous sentence. After the two-statement version it does not, and the history still shows when the flag was set. In `article` itself every revision but the newest is a history row, so this needs the application-time design ([model C](decisions/0001-time-model.md)), where old revisions are ordinary rows, or the text kept in a table of its own ([the split design](growth-and-partitioning.md#storing-it-smaller)), where a text can be blanked.

### Who may rewrite the past

`DELETE HISTORY` needs a privilege of its own. Writing a version that never existed, or erasing one, does not. The server takes the time from the session, and with `secure_timestamp = NO`, the default, a session may set both its clock and `system_versioning_insert_history`. Tried with the rights of an account that may `SELECT`, `INSERT`, `UPDATE` and `DELETE` in one table and nothing else:

| the ordinary account tries | result |
|---|---|
| `CREATE TABLE` | refused, error 1142 (it really is ordinary) |
| `INSERT` a history row dated 2001 | accepted |
| `UPDATE` with its session clock set back to 2016 | accepted, and the version it replaced is gone ([MDEV-41003](https://jira.mariadb.org/browse/MDEV-41003)) |
| `DELETE HISTORY` | refused, error 1142 |

Afterwards the table's whole history read: "2001: a version that never existed", "2016: what someone wants on record". What was really said is not in it any more.

So under the default configuration the history is exactly as trustworthy as every account that can write to the table. `secure_timestamp = YES` closes both doors, and also closes the one this project came in by: the direct load of dated history. A system that needs its history to be evidence should set it, and should bring in old history before it does.

### Who made the change

The server records when a row changed, never who (requested as [MDEV-16858](https://jira.mariadb.org/browse/MDEV-16858)). Our `editor` column holds Wikipedia's user names because the load put them there. For the database account, a column and a small trigger are enough, and versioning then keeps the answer for every version:

```sql
CREATE TABLE who (id INT PRIMARY KEY, body VARCHAR(100),
                  changed_by VARCHAR(128) NOT NULL DEFAULT CURRENT_USER()) WITH SYSTEM VERSIONING;
CREATE TRIGGER who_before_update BEFORE UPDATE ON who FOR EACH ROW SET NEW.changed_by = CURRENT_USER();
```

Both versions of the test row carry an account name. Triggers and system versioning are not rivals here: the trigger adds a fact, the server keeps its history.

### Changing the table

`ALTER TABLE` on a versioned table is refused (error 4119) until the session sets `system_versioning_alter_history = KEEP`. Then it runs, and the past is rewritten into the new shape: after `ADD COLUMN licence VARCHAR(20) NOT NULL DEFAULT 'CC BY-SA 4.0'`, the oldest version claims to have had that licence. The history says what the rows held, in today's columns; it does not say what the table looked like. `OPTIMIZE TABLE` is refused the same way.

### Searching the past

A `FULLTEXT` index answers only for current rows. A word that only an old version contains is found by `LIKE` (1 row) and not by `MATCH` (0 rows), confirmed as [MDEV-36991](https://jira.mariadb.org/browse/MDEV-36991). The web page's search therefore uses `LIKE` and reads every version: about a second over our 161 MB.

### The session-wide time machine reads, it does not write

Under `SET system_versioning_asof = '2005-01-01'`, counting the articles gave 14 as a `SELECT`, and 30 inside `SET @v = (SELECT ...)` and inside `CREATE TABLE ... AS SELECT`. The documentation says the setting has no effect on DML; the two forms above are easy to take for reads. A report copied into a table "as of last year" this way silently holds today's data.

### Large rows, small changes

Every edit stores the whole row again: 63 bytes kept for every byte of length changed, and 14% of all versions are texts the article had before ([measured in M3](growth-and-partitioning.md#how-it-grows)). For documents, keep the text out of the versioned row.

### Time before 1970, and after 2038

The period columns are `TIMESTAMP`s. A history row that starts in 1969 is refused (error 1292), so nothing older than 1970 can be system time. The "still current" marker is the largest `TIMESTAMP`: 2106-02-07 on this server, 2038-01-19 before MariaDB 11.5. For dates outside that range, an application-time period with `DATE` or `DATETIME` columns has no such limit.

### What the older designs do better

One thing: **importing a history that already exists.** For the revision table and for the trigger tables, loading 24 years of dated history was an ordinary `INSERT`, because their history is ordinary rows with ordinary date columns. For the versioned table it needed `system_versioning_insert_history`, a server that permits it, and care with partitions. It is the main design question of this project for a reason ([the decision](decisions/0001-time-model.md)).

## So when is it the right answer?

Use system versioning when:

- the table is the system of record and its changes happen in it, so that the server's clock is the true time of each change;
- the question is "what did this row, or this whole table, look like then", and you want to ask it with the queries you already have;
- completeness matters more than cleverness: cascades, bulk statements and forgotten code paths must all be caught;
- the rows are of ordinary size.

Look further when:

- single versions must be removable (keep that column unversioned, or outside the table);
- the history must hold up against those who can write to the table (`secure_timestamp`, or an append-only store elsewhere);
- the dates are not your database's own: someone else's history, corrections to the past, dates before 1970 (an application-time period, alone or beside system versioning);
- the rows are large documents with small edits (version a pointer, store the text once).

**And for Wikipedia itself?** The irony the brief points to is real: the software that keeps the world's best-known edit history on MariaDB writes that history by hand. But three of the four reasons above are Wikipedia's daily business. Its administrators hide single revisions; its history is corrected after the fact by page merges and imports; and its rows are long texts changed a sentence at a time, which is why MediaWiki keeps the text out of the revision row, in tables of its own. A system-versioned `article` table as built here would serve the reader's time machine well and the administrator's tools badly. What would serve both is the combination this project arrived at from three sides: a versioned row for the metadata, the text stored once and outside it, and an application-time period wherever the past itself may change.
