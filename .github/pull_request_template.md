## What this changes

<!-- One or two sentences, and the task in docs/PLAN.md it belongs to (e.g. "B1"). -->

## How I tested it

- [ ] `python scripts/setup.py` (or `python scripts/build_sql.py` and `mariadb -u root -p --table --abort-source-on-error -e "source run_all.sql"`) ends with `N / N checks passed`
- [ ] If I touched `app/`: `pytest app/tests` passes, and I opened the pages I changed
- [ ] If I touched an experiment: it ends with `N / N ... checks passed`, and the numbers in the docs come from its output
- [ ] Anything else I ran and what it showed:

## AI use

- Tool(s) used:
- [ ] Added a line for each use to `docs/AI_USE.md`, with the prompt saved under `docs/prompts/`
- [ ] I have read every line of this change and can explain it

## Review

<!-- Ask one teammate to review. Do not merge until they approve. -->
