#!/usr/bin/env python3
"""Run SQL scripts with the mariadb client, using the connection settings in .env.

    python scripts/run_sql.py                         runs run_all.sql
    python scripts/run_sql.py sql/03_time_machine.sql runs one script
    python scripts/run_sql.py --query "SELECT 1"      runs one statement

Connection settings come from environment variables, or from a .env file in the
repository root (copy .env.example; .env is gitignored, so the password stays on your
machine): WTM_DB_HOST, WTM_DB_PORT, WTM_DB_USER, WTM_DB_PASSWORD. If WTM_DB_PASSWORD is
not set at all, the client asks for the password; set it to an empty value for a server
without one. Because nothing has to be typed when .env has the password, coding agents
can run the build and the checks too.

Always runs the client with --table and --abort-source-on-error: without the second,
the client carries on after an error inside a sourced file and exits with status 0.
Run it from anywhere; paths are resolved from the repository root.
Uses only the Python standard library (3.9 or newer).
"""

import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULTS = {"WTM_DB_HOST": "127.0.0.1", "WTM_DB_PORT": "3306", "WTM_DB_USER": "root",
            "WTM_DB_PASSWORD": ""}


def settings():
    """Defaults, overridden by .env, overridden by the environment.

    Also says whether a password was configured at all: WTM_DB_PASSWORD set to an empty
    value means "no password", while not setting it means "ask me".
    """
    values = dict(DEFAULTS)
    configured = set()
    env_file = ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip().strip('"').strip("'")
                configured.add(key.strip())
    for key in DEFAULTS:
        if key in os.environ:
            values[key] = os.environ[key]
            configured.add(key)
    return values, "WTM_DB_PASSWORD" in configured


def find_client():
    """The mariadb client: on the PATH, or in the newest Windows install folder."""
    for name in ("mariadb", "mysql"):
        found = shutil.which(name)
        if found:
            return found
    installs = glob.glob(r"C:\Program Files\MariaDB *\bin\mariadb.exe")
    if installs:
        def version(path):
            folder = Path(path).parent.parent.name  # "MariaDB 12.3"
            return [int(part) for part in folder.split()[-1].split(".") if part.isdigit()]
        return max(installs, key=version)
    sys.exit("Could not find the mariadb client. Install MariaDB, or add its bin folder "
             "to the PATH.")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("script", nargs="?", default="run_all.sql",
                        help="SQL file to run, relative to the repository root")
    parser.add_argument("--query", help="run this SQL instead of a file")
    args = parser.parse_args()

    config, password_configured = settings()
    command = [find_client()]
    options_file = None
    if config["WTM_DB_PASSWORD"]:
        # A temporary option file keeps the password off the command line, where other
        # programs could see it. It must be the client's first option.
        handle, options_file = tempfile.mkstemp(suffix=".cnf")
        with os.fdopen(handle, "w", encoding="utf-8") as f:
            f.write("[client]\npassword=\"" + config["WTM_DB_PASSWORD"].replace("\\", "\\\\")
                    .replace('"', '\\"') + "\"\n")
        command.append(f"--defaults-extra-file={options_file}")
    command += [f"--host={config['WTM_DB_HOST']}", f"--port={config['WTM_DB_PORT']}",
                f"--user={config['WTM_DB_USER']}", "--table", "--abort-source-on-error",
                "--default-character-set=utf8mb4"]
    if not password_configured:
        # Not even an empty WTM_DB_PASSWORD: let the client ask. (An agent cannot answer
        # the prompt, which is why agents need WTM_DB_PASSWORD in .env.)
        print("WTM_DB_PASSWORD is not set in .env or the environment, so the client will "
              "ask for the password.", file=sys.stderr)
        command.append("--password")
    if args.query:
        command += ["--execute", args.query]
    else:
        script = Path(args.script)
        if not (ROOT / script).exists():
            sys.exit(f"No such file: {script}")
        command += ["--execute", f"source {script.as_posix()}"]
    try:
        result = subprocess.run(command, cwd=ROOT)
    finally:
        if options_file:
            os.remove(options_file)
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
