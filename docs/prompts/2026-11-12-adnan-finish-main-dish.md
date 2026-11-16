# 2026-11-12 to 14, Adnan S, Claude Code: finishing the main dish (milestones M2 to M7)

**Tool:** Claude Code desktop app. One session over three days; it was interrupted by usage limits several times and resumed each time with "Please continue from where you left off." Model: Claude Fable 5.2 from 12 to 13 November (everything up to the README); Claude Opus 5.5 on 14 November, after Adnan switched the model and wrote "Try again" (the last records, small corrections to the docs, and the test runs on MariaDB 10.11, 11.4 and 12.3 in Docker).

**Prompt (Adnan's words, complete):**

> Complete the entirety of the rest of the project. But before you do I need you to keep in mind other teams have also chosen the same project. for us to stand out i need you to add features that are very unique and eye catching to the maria DB guys. Something that solves a problem they already have or anything that immediately tells them why our project is of higher quality. Complete it fully now, research, test, build, etc.

**Context the agent used:** `AGENTS.md`, `CONTRIBUTING.md` and `docs/PLAN.md` of this repository; the state of `main` after pull request #2 (Siddhartha's first version of the web page); the area description and the evaluation prompt on the [MariaDB project page](https://mariadb.org/bachelor_hackathon_2026-09/); the MariaDB documentation on [system-versioned tables](https://mariadb.com/docs/server/reference/sql-structure/temporal-tables/system-versioned-tables); MariaDB's issue tracker (jira.mariadb.org) for known problems of the feature; and MariaDB's skill for AI agents on the feature (github.com/MariaDB/skills).

**How it decided what "unique" should be.** It first tested the feature's edges on a throwaway MariaDB 12.3.3 server and compared what it saw with the issue tracker. Three things followed from that and were not in the plan: the wrong-result consequence of MDEV-29674 (found while building M3 exactly as the plan described it), the audit of MariaDB's agent skill, and the `ORDER BY row_end LIMIT 1` measurement. The rest follows `docs/PLAN.md`.

**What it produced** (branch `adnan/finish-main-dish`; nothing was committed or pushed by the agent):

- **M2 and M6, the web page** (`app/`): built on Siddhartha's skeleton. New: `db.py`, `moments.py`, `differ.py`, `timeline.py`, `lab.py`, the templates `base`, `_picture`, `diff`, `phrase`, `search`, `about`, `lab_pages`, `lab_page`, `missing`, `error`, `static/style.css`, `static/timeline.js`. Rewritten: `app.py`, `renderer.py`, the templates `index`, `article`, `history`, and `app/README.md`. Tests: `tests/conftest.py`, `tests/test_parts.py` (23 tests), `tests/test_pages.py` (27), and 27 tests added to Siddhartha's `tests/test_renderer.py` (his 16 are unchanged and pass).
- **SQL:** `sql/04_lab.sql`; queries 8 to 11 in `sql/03_time_machine.sql`; four checks in `sql/90_checks.sql`; `run_all.sql`.
- **M3, M4, M5, the experiments:** `experiments/harness.sql`, `experiments/growth/run.sql`, `experiments/time-models/run.sql`, `experiments/before-after/run.sql`, `experiments/backup/compare.sql`, and the recorded output of each.
- **Write-ups:** `docs/growth-and-partitioning.md`, `docs/before-and-after.md`, the rewritten `docs/decisions/0001-time-model.md`, `README.md`.
- **For MariaDB:** `upstream/README.md`, `upstream/mdev-29674-wrong-results.sql`, `upstream/skill-audit/` (the audit script, MariaDB's file as audited with its licence, and the proposed replacement).
- **Scripts and CI:** `scripts/setup.py`, `scripts/backup_check.py`, `scripts/check_output.py`, `--set` in `scripts/run_sql.py`, `.github/workflows/ci.yml`.
- **Records:** this file, the row in `docs/AI_USE.md`, the status in `docs/PLAN.md`, `docs/self-assessment/2026-11-09.md`, the map and the "facts that are easy to get wrong" in `AGENTS.md`, the checks in `CONTRIBUTING.md`, `docs/team/START_HERE.md` and the pull request template.

**Checked by the agent, on MariaDB 12.3.3 (Windows 11):**

- `python scripts/setup.py` ends with `12 / 12 checks passed`;
- the three experiments end with 9, 8 and 7 checks passed, the skill audit with 5, the backup check with 4;
- `pytest app/tests`: 93 passed; without a database the 27 page tests are skipped, with `WTM_REQUIRE_DB=1` they fail;
- every page was opened in a browser; the screenshots in `docs/images/` are of the running page;
- every number in the write-ups was copied from the recorded output files;
- on 14 November, a fresh copy of the files git would ship (no `build/`, no `.env`) built and passed everything above: `python scripts/setup.py --experiments --runs 1`, `pytest app/tests` (93 passed), `python scripts/backup_check.py` (4 / 4), `python scripts/fetch_revisions.py --check`;
- on 14 November, the steps of `.github/workflows/ci.yml` were run locally in Docker on the official images **MariaDB 10.11.19, 11.4.13 and 12.3.3** (Linux): on all three the build ended with 12 / 12 checks, the experiments with 9, 8 and 7, the skill audit with 5 and the backup comparison with 4, `pytest` passed 93 tests against the container, and the bug reproduction returned 0 rows after the `UPDATE`, as on Windows.

**Not checked, and to be checked by us before we rely on it:**

- **The CI workflow on GitHub** has not run: the agent does not push. Its steps passed locally in Docker on all three versions (above), so a failure there would point to a difference between GitHub's runner and Docker Desktop, not to the scripts.
- **Nothing was submitted to MariaDB.** `upstream/README.md` says so, and has the text ready.
- The agent wrote all of this in one sitting. Every line still has to be read by the person who presents it (AGENTS.md: "The person you work for must be able to explain every line").

**A mistake of its own that its tests caught:** the lab's forms were first protected by comparing the submitted token with the session's token, and two empty strings compared equal, so a visitor without a session could post without a token. `test_lab_refuses_a_form_without_its_token` failed on it; `lab.py` now refuses when the session has no token.
