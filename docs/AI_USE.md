# AI-use log

The team guide asks for every use of an AI tool to be traceable: which tool, which part of the work it touched, the prompt, and what it produced. One line per use, newest at the bottom, added in the same pull request as the work it produced. We are responsible for everything we submit, AI-assisted or not.

**How to add an entry**

1. Save the prompt (your words to the tool, plus anything important you added later in the conversation) as `docs/prompts/<date>-<name>-<topic>.md`. Summarise very long conversations, but keep the instructions that shaped the result.
2. Add a row below: date, who, tool and model, the files or part it touched, a link to the prompt file, and the pull request or commits that contain the result.
3. If later work replaces what the AI produced, say so in a new row; do not delete old rows.

| Date | Who | Tool | What it touched | Prompt | Result |
|------|-----|------|-----------------|--------|--------|
| 2026-11-04 | Adnan S | Claude Code (Claude Opus 5.5) | Milestone M1: the data set and its download script, the schema and history load, the demo queries and checks, CI, README, AGENTS.md, CONTRIBUTING.md and the planning docs | [prompt](prompts/2026-11-04-adnan-m1-foundation.md) | Branch `adnan/m1-foundation`, pull request #1 |
| 2026-11-05 | Siddhartha | Antigravity (Google DeepMind) | Milestone M2: `app/app.py`, `app/renderer.py`, `app/requirements.txt`, `app/README.md`, `app/templates/` (index, article, history), `app/tests/test_renderer.py` | [prompt](prompts/2026-11-05-siddhartha-m2-time-machine-page.md) | Branch `siddhartha/time-machine-page`, pull request #2 |
| 2026-11-12 to 14 | Adnan S | Claude Code (Claude Fable 5.2, then Claude Opus 5.5 from 14 Nov) | Milestones M2 to M7: the completed web page with its diff, lab and tests (`app/`, building on and replacing parts of the row above: `app.py`, `renderer.py` and the three templates were rewritten, the 16 renderer tests kept); `sql/04_lab.sql` and additions to `sql/03_time_machine.sql` and `sql/90_checks.sql`; the three experiments and the backup check (`experiments/`, `scripts/backup_check.py`); `scripts/setup.py`, `scripts/check_output.py`; the CI workflow; the findings for MariaDB (`upstream/`); `README.md`, `docs/growth-and-partitioning.md`, `docs/before-and-after.md`, `docs/decisions/0001-time-model.md`, `app/README.md`; the screenshots in `docs/images/` | [prompt](prompts/2026-11-12-adnan-finish-main-dish.md) | Branch `adnan/finish-main-dish`; pull request to be opened |
