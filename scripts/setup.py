#!/usr/bin/env python3
"""One command from a fresh clone to a loaded, checked time machine.

    python scripts/setup.py                  build the database and run every demo and check
    python scripts/setup.py --app            ... then start the web page on http://127.0.0.1:5000
    python scripts/setup.py --experiments    ... then run the three experiments and the skill audit

What it does, in order:

1. turns the committed revision files into build/load_revisions.sql (scripts/build_sql.py),
   unless that file is already there and newer than the data;
2. runs run_all.sql through scripts/run_sql.py, which drops and recreates the
   wiki_time_machine database, loads it, runs the demo queries and ends with
   "N / N checks passed";
3. with --experiments, runs experiments/*/run.sql and upstream/skill-audit/run.sql;
4. with --app, starts the web page (it needs Flask and PyMySQL: pip install -r app/requirements.txt).

Connection settings come from .env or the environment, exactly as for run_sql.py: copy
.env.example to .env and fill in WTM_DB_PASSWORD. Uses only the Python standard library.
"""

import argparse
import importlib.util
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOAD_FILE = ROOT / "build" / "load_revisions.sql"
EXPERIMENTS = ("experiments/growth/run.sql", "experiments/time-models/run.sql",
               "experiments/before-after/run.sql", "upstream/skill-audit/run.sql")


def step(text):
    print(f"\n== {text}", flush=True)


def run(*command):
    """Run a command of this repository with the same Python, and stop if it fails."""
    result = subprocess.run([sys.executable, *command], cwd=ROOT)
    if result.returncode != 0:
        sys.exit(f"\nStopped: `python {' '.join(command)}` failed (exit status {result.returncode}).")


def load_file_is_current():
    """True if build/load_revisions.sql exists and no data file is newer than it."""
    if not LOAD_FILE.exists():
        return False
    built = LOAD_FILE.stat().st_mtime
    sources = [ROOT / "data" / "pages.tsv", ROOT / "scripts" / "build_sql.py",
               *(ROOT / "data" / "revisions").glob("*.jsonl.xz")]
    return all(source.stat().st_mtime <= built for source in sources)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--app", action="store_true", help="start the web page afterwards")
    parser.add_argument("--experiments", action="store_true",
                        help="also run the experiments and the skill audit (several minutes)")
    parser.add_argument("--runs", type=int, metavar="N",
                        help="timed runs per statement in the experiments (default 7)")
    args = parser.parse_args()

    if load_file_is_current():
        step("1/2  build/load_revisions.sql is up to date")
    else:
        step("1/2  Turning the revision files into SQL (about 15 seconds)")
        run("scripts/build_sql.py")

    step("2/2  Loading the database and running the demos and checks (run_all.sql)")
    run("scripts/run_sql.py")

    if args.experiments:
        extra = ["--set", f"runs={args.runs}"] if args.runs else []
        for script in EXPERIMENTS:
            step(f"Experiment: {script}")
            run("scripts/run_sql.py", script, *extra)

    if args.app:
        missing = [name for name in ("flask", "pymysql") if importlib.util.find_spec(name) is None]
        if missing:
            sys.exit("\nThe web page needs Flask and PyMySQL. Install them and run this again:\n"
                     "    pip install -r app/requirements.txt")
        step("Starting the web page: http://127.0.0.1:5000  (Ctrl+C stops it)")
        run("app/app.py")
    else:
        print("\nDone. Next: `python scripts/setup.py --app` opens the time machine in a browser,\n"
              "or ask the database yourself; the README's quick start has a first query.")


if __name__ == "__main__":
    main()
