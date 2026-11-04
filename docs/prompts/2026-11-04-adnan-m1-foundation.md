# 2026-11-04, Adnan S, Claude Code: starting the main dish (milestone M1)

**Tool:** Claude Code desktop app, model Claude Opus 5.5.

**Prompt (summary of the request; the full session transcript is kept by Adnan):**

> We are starting work on the main dish we selected earlier: system-versioned tables (area 3, the Wikipedia time machine). There are three of us, and my two teammates, Siddhartha and Rahmath, have not yet worked with coding agents or with this kind of collaboration on GitHub. Give me something I can send them so they can use their agents and get started, and start the work yourself: get about 25% of the main dish done now.

**Context the agent used:** the earlier session in which the team chose area 3, the area description and evaluation prompt on the [MariaDB project page](https://mariadb.org/bachelor_hackathon_2026-09/), the team guide (process rules, AI-use rules, dates), and the MariaDB documentation on [system-versioned tables](https://mariadb.com/docs/server/reference/sql-structure/temporal-tables/system-versioned-tables).

**What it produced:**

- `data/articles.txt` (the choice of 30 articles, made from measured revision counts and sizes), `scripts/fetch_revisions.py`, and the downloaded data in `data/revisions/` and `data/pages.tsv`
- `scripts/build_sql.py`, `sql/01_schema.sql`, `sql/02_build_history.sql`, `sql/03_time_machine.sql`, `sql/90_checks.sql`, `run_all.sql`
- `.github/workflows/ci.yml` and the pull request template
- `README.md`, `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `docs/PLAN.md`, `docs/team/START_HERE.md`, `docs/decisions/0001-time-model.md`, `docs/self-assessment/`, this log

**Checked by:** running `run_all.sql` on MariaDB 12.3.3 (8 / 8 checks pass), and by the team's review of pull request #1 (branch `adnan/m1-foundation`).
