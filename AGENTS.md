# Instructions for AI coding agents

Read this file, [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/PLAN.md](docs/PLAN.md) before you change anything. They apply to every agent working on this repository (Claude Code reads this file through `CLAUDE.md`).

## The project

A Wikipedia time machine built on MariaDB's system-versioned tables, for area 3 of the [MariaDB student database projects, 2026-09](https://mariadb.org/bachelor_hackathon_2026-09/). MariaDB engineers grade the `main` branch, partly with an AI prompt that checks the README's claims against the code. It is a university team project (Constructor University, Capstone I), and the supervisor grades the process from the git history: branches, pull requests, reviews, and a traceable record of AI use.

The person you work for must be able to explain every line you write at the final presentation. Explain what you do and why, in plain words, and prefer simple code they can follow over clever code.

## Map

| Path | What it is | Owner |
|------|------------|-------|
| `data/articles.txt` | The stated set of 30 articles | Adnan |
| `data/revisions/*.jsonl.xz`, `data/pages.tsv` | Their full revision history before 2026-11-01, committed | Adnan |
| `scripts/fetch_revisions.py` | Downloads the history from the MediaWiki API (do not run it without a reason) | Adnan |
| `scripts/build_sql.py` | Turns the data into `build/load_revisions.sql` (generated, gitignored) | Adnan |
| `scripts/run_sql.py` | Runs a SQL script with the settings from `.env`, without a password prompt | Adnan |
| `sql/01_schema.sql` | Tables `page` and `revision` (how MediaWiki does it) and `article` (`WITH SYSTEM VERSIONING`) | Adnan |
| `sql/02_build_history.sql` | Fills `article`'s history with the real save times | Adnan |
| `sql/03_time_machine.sql` | Demo queries with `FOR SYSTEM_TIME` | Adnan |
| `sql/90_checks.sql` | Self-checks; fails the run if one fails | Adnan |
| `run_all.sql` | Runs all of the above in order | Adnan |
| `app/` | The time machine web page (milestone M2) | Siddhartha |
| `experiments/growth/`, `docs/growth-and-partitioning.md` | Growth and partitioning (M3) | Rahmath |
| `experiments/before-after/`, `docs/before-and-after.md` | Without system versioning (M5) | Rahmath |
| `docs/decisions/` | Design decisions, one file each | whoever decides, reviewed by the team |
| `docs/AI_USE.md`, `docs/prompts/`, `docs/self-assessment/` | Process records | everyone, own entries |

Stay inside the files your task owns. If your task needs a change in someone else's files, for example a new column in `sql/01_schema.sql`, stop and tell the user, so the owner can make it or agree to it.

## Build and check

From the repository root, with a MariaDB 10.11 or newer server running:

```bash
python scripts/build_sql.py
python scripts/run_sql.py
```

`run_sql.py` runs `run_all.sql` (or the script you name, e.g. `python scripts/run_sql.py experiments/growth/run.sql`, or `--query "SELECT ..."`) with the connection settings from `.env`. If `.env` is missing or has no password, the client asks for one, which you cannot answer: ask the user to copy `.env.example` to `.env` and fill in their local password. Never ask them to paste a password into the chat, and never print `.env`.

The output must end with `N / N checks passed`. Run it before every push that touches `data/`, `scripts/` or `sql/`. The same build without the helper is:

```bash
mariadb -u root -p --table --abort-source-on-error -e "source run_all.sql"
```

Two details in that command matter, so keep them in every doc and script:

- `--abort-source-on-error`: without it, the client carries on after an error inside a sourced file and exits with status 0, so a broken build looks like a good one.
- `-e "source ..."` instead of `< run_all.sql`: PowerShell does not support `<` redirection.

On Windows, `mariadb` may not be on the PATH; the client is in `C:\Program Files\MariaDB 12.3\bin\` (in PowerShell: `& "C:\Program Files\MariaDB 12.3\bin\mariadb.exe" ...`).

`python scripts/fetch_revisions.py --check` verifies the committed data without downloading anything. Do not re-download the data (`fetch_revisions.py` without `--check`) unless the task is to change the data set: it sends hundreds of requests to Wikipedia.

## Rules

1. **Never commit to `main` and never push to it.** Start every task from an up-to-date `main` on a new branch named `<your-name>/<topic>`, for example `siddhartha/time-machine-page`.
2. **Small commits, clear messages.** Imperative mood, saying what changed and why: `Add the as-of page for one article`. Ask the user before each commit and push, and show them what will be committed.
3. **Open a pull request for every change** (use `.github/pull_request_template.md`), and ask a teammate to review it. Nobody merges their own pull request without an approval.
4. **Log AI use in the same pull request.** Add one line per use to `docs/AI_USE.md` and save the prompt under `docs/prompts/` (see the format there). A record that does not match the code is worse than none, so update it when the code changes.
5. **Keep the README true.** Document only what works on `main`. Mark planned work as planned. Numbers in the README must come from a script in the repository, with the MariaDB version, the machine and the number of runs.
6. **No secrets in the repository.** Database passwords come from environment variables (`WTM_DB_PASSWORD`) or the gitignored `.env`; `.env.example` shows the keys. The app reads the same keys.
7. **UTC everywhere.** Every connection and script sets `time_zone = '+00:00'`; show times as UTC.
8. **Use the history, not the revision table, in new features.** The app and the demos read `article` with `FOR SYSTEM_TIME`. The `revision` table is the "before" model, used for comparisons only.
9. **Python:** 3.10 or newer, standard library first. The app may use Flask and PyMySQL, listed in `app/requirements.txt`. Explain any other dependency to the user before adding it.
10. **SQL:** keywords in capitals, a comment above each statement saying what it shows or why it is there, scripts that run on a fresh server and can be run twice.

## Facts that are easy to get wrong

- `system_versioning_insert_history` needs MariaDB 10.11 or later, and works only while `secure_timestamp` allows changing the session timestamp.
- MariaDB refuses a version whose period is empty (`row_start = row_end`, error 4112) and adds `row_end` to every unique key, so two versions of one row cannot end at the same instant.
- The `row_end` of current rows is 2038-01-19 before MariaDB 11.5 and 2106-02-07 from 11.5 on 64-bit systems. Never hard-code either.
- `FOR SYSTEM_TIME AS OF t` returns the rows with `row_start <= t < row_end`. `BETWEEN a AND b` includes `b`; `FROM a TO b` does not.
- A `TIMESTAMP '...'` literal needs a time: `TIMESTAMP '2015-06-01 00:00:00'`, not `TIMESTAMP '2015-06-01'` (error 1525).
- MariaDB's `REGEXP_SUBSTR` takes exactly two arguments; there is no position or occurrence argument.
- Partitioning by `SYSTEM_TIME` is not possible with transaction-precise (`BIGINT UNSIGNED`) history.
- `mariadb-dump` skips history unless given `--dump-history` (10.11 and later).
