#!/usr/bin/env python3
"""Back up the versioned tables, restore them, and check that the history came back.

    python scripts/backup_check.py

mariadb-dump leaves the history of system-versioned tables out unless it is given
--dump-history (MariaDB 10.11 and later). This script shows both outcomes:

1. dumps `article` and `lab_page` with --dump-history into build/backup_with_history.sql
   and restores that into a database called wtm_restored;
2. dumps them again the default way into build/backup_default.sql and restores that
   into wtm_restored_plain;
3. runs experiments/backup/compare.sql, which compares both with the original, prints
   "N / N backup checks passed" and drops the two databases again.

Connection settings come from .env or the environment, as for scripts/run_sql.py.
Uses only the Python standard library.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_sql  # noqa: E402  (the helper next to this file: settings and the client's path)

ROOT = run_sql.ROOT
TABLES = ("article", "lab_page")


def main():
    config, password_configured = run_sql.settings()
    client = Path(run_sql.find_client())
    # mariadb-dump lives next to the client (mysqldump on older installations).
    dumps = [client.with_name(name + client.suffix) for name in ("mariadb-dump", "mysqldump")]
    dump_tool = next((tool for tool in dumps if tool.exists()), None)
    if dump_tool is None:
        sys.exit(f"Could not find mariadb-dump next to {client}")

    options_file = None
    connection = []
    if config["WTM_DB_PASSWORD"]:
        # As in run_sql.py: a temporary option file keeps the password off the command line.
        handle, options_file = tempfile.mkstemp(suffix=".cnf")
        with os.fdopen(handle, "w", encoding="utf-8") as f:
            f.write("[client]\npassword=\"" + config["WTM_DB_PASSWORD"].replace("\\", "\\\\")
                    .replace('"', '\\"') + "\"\n")
        connection.append(f"--defaults-extra-file={options_file}")
    connection += [f"--host={config['WTM_DB_HOST']}", f"--port={config['WTM_DB_PORT']}",
                   f"--user={config['WTM_DB_USER']}"]
    if not password_configured:
        connection.append("--password")

    def run(tool, *arguments, output=None):
        command = [str(tool), *connection, *arguments]
        with (open(output, "wb") if output else open(os.devnull, "wb")) as target:
            result = subprocess.run(command, cwd=ROOT, stdout=target if output else None)
        if result.returncode != 0:
            sys.exit(f"Stopped: {Path(tool).name} {' '.join(arguments)} failed.")

    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    with_history = build / "backup_with_history.sql"
    default_dump = build / "backup_default.sql"
    try:
        print("Dumping article and lab_page with --dump-history ...", flush=True)
        run(dump_tool, "--dump-history", "--default-character-set=utf8mb4", "wiki_time_machine", *TABLES,
            output=with_history)
        print("Dumping them again the default way ...", flush=True)
        run(dump_tool, "--default-character-set=utf8mb4", "wiki_time_machine", *TABLES, output=default_dump)
        print(f"  with history: {with_history.stat().st_size / 1e6:.1f} MB, "
              f"default: {default_dump.stat().st_size / 1e6:.1f} MB", flush=True)

        print("Restoring both into databases of their own ...", flush=True)
        run(client, "--execute", "CREATE OR REPLACE DATABASE wtm_restored; "
                                 "CREATE OR REPLACE DATABASE wtm_restored_plain")
        run(client, "--default-character-set=utf8mb4", "--abort-source-on-error", "wtm_restored",
            "--execute", f"source {with_history.relative_to(ROOT).as_posix()}")
        run(client, "--default-character-set=utf8mb4", "--abort-source-on-error", "wtm_restored_plain",
            "--execute", f"source {default_dump.relative_to(ROOT).as_posix()}")

        print("Comparing with the original ...", flush=True)
        run(client, "--table", "--abort-source-on-error", "--execute", "source experiments/backup/compare.sql")
    finally:
        if options_file:
            os.remove(options_file)
        for leftover in (with_history, default_dump):
            leftover.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
