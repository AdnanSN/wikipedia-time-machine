#!/usr/bin/env python3
"""Check the saved output of the SQL scripts: did every check in them pass?

    python scripts/check_output.py run_all.out:12 growth.out:9 models.out

Each argument is a file holding the output of one script (run_all.sql or an
experiment), optionally followed by :N, the smallest number of checks it must contain.
A file is good if it has a summary line "N / N ... checks passed" with both numbers
equal, at least the required number of checks, and no line that starts with ERROR.

CI uses this so that a script that stopped early, or printed fewer checks than it
should, cannot pass for a successful run. Uses only the Python standard library.
"""

import re
import sys
from pathlib import Path

SUMMARY = re.compile(r"\|\s*(\d+) / (\d+) [a-z' -]*checks passed\s*\|")


def problems_in(path, at_least):
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    errors = [line for line in text.splitlines() if line.startswith("ERROR")]
    if errors:
        return [f"an SQL error: {errors[0]}"]
    summaries = SUMMARY.findall(text)
    if not summaries:
        return ["no 'N / N checks passed' line: the script did not reach its end"]
    passed, total = (int(number) for number in summaries[-1])
    found = []
    if passed != total:
        found.append(f"only {passed} of {total} checks passed")
    if total < at_least:
        found.append(f"{total} checks, expected at least {at_least}")
    return found


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    failed = False
    for argument in sys.argv[1:]:
        path, _, minimum = argument.partition(":")
        if not Path(path).exists():
            print(f"FAIL  {path}: no such file")
            failed = True
            continue
        found = problems_in(path, int(minimum or 1))
        if found:
            failed = True
            print(f"FAIL  {path}: " + "; ".join(found))
        else:
            print(f"ok    {path}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
