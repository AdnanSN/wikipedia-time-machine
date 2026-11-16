# 2026-11-04, Adnan S, Claude Code: starting the main dish (milestone M1)

**Tool:** Claude Code desktop app, model Claude Opus 5.5.

**The request, in summary** (the full session transcript is kept by Adnan): start the main dish, area 3; write onboarding material so that the two teammates can start working with their own coding agents; and build the first quarter of the project.

**Context the agent used:** the earlier session in which the team chose area 3, the area description and evaluation prompt on the [MariaDB project page](https://mariadb.org/bachelor_hackathon_2026-09/), the team guide (process rules, AI-use rules, dates), and the MariaDB documentation on [system-versioned tables](https://mariadb.com/docs/server/reference/sql-structure/temporal-tables/system-versioned-tables).

**What it produced:**

- `data/articles.txt` (the choice of 30 articles, made from measured revision counts and sizes), `scripts/fetch_revisions.py`, and the downloaded data in `data/revisions/` and `data/pages.tsv`
- `scripts/build_sql.py`, `sql/01_schema.sql`, `sql/02_build_history.sql`, `sql/03_time_machine.sql`, `sql/90_checks.sql`, `run_all.sql`
- `.github/workflows/ci.yml` and the pull request template
- `README.md`, `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `docs/PLAN.md`, `docs/team/START_HERE.md`, `docs/decisions/0001-time-model.md`, `docs/self-assessment/`, this log

**Checked by:** running `run_all.sql` on MariaDB 12.3.3 (8 / 8 checks pass), and by the team's review of pull request #1 (branch `adnan/m1-foundation`).
