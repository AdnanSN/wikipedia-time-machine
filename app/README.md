# Wikipedia Time Machine – web app

**Milestone M2 · Owner: Siddhartha**

A small Flask application that lets you pick any of the 30 Wikipedia
articles in the database and read it as it looked at any moment in time.
It queries the `article` table with MariaDB's `FOR SYSTEM_TIME` clause —
never the `revision` table.

## Prerequisites

- Python 3.10 or newer
- A running MariaDB 10.11+ server with the database loaded
  (`python scripts/run_sql.py` from the repository root; see the main README)
- A `.env` file in the repository root (copy `.env.example` and fill in
  `WTM_DB_PASSWORD`)

## Install and run

```bash
# from the repository root:
pip install -r app/requirements.txt
python app/app.py
```

Then open <http://127.0.0.1:5000> in your browser.

## Environment variables

The app reads the same keys as `scripts/run_sql.py`:

| Variable | Default | What it is |
|---|---|---|
| `WTM_DB_HOST` | `127.0.0.1` | MariaDB host |
| `WTM_DB_PORT` | `3306` | MariaDB port |
| `WTM_DB_USER` | `root` | database user |
| `WTM_DB_PASSWORD` | *(empty)* | database password (required) |
| `WTM_DB_NAME` | `wiki_time_machine` | database name |

Set them in `.env` or in the shell; shell variables take precedence.

## Running the tests

```bash
# from the repository root:
pip install -r app/requirements.txt pytest
pytest app/tests/ -v
```

The tests cover the wikitext renderer only and need no database.

## What the app does and does not render

The wikitext renderer handles: section headings, bold, italic, internal
Wikipedia links, external links, bullet lists, numbered lists, and plain
paragraphs.

It deliberately skips: templates (`{{...}}`), tables, `<ref>` footnotes,
and images (`[[File:...]]`). The article page tells the reader this.

## Times

All timestamps come from the database with `time_zone = '+00:00'` set on
every connection, and are displayed as UTC.
