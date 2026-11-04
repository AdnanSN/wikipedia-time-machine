# How we work

Half of every team member's mark is the process, and the supervisor reads it from the git history: who did what, on which branch, through which pull request, reviewed by whom, with which AI help. This page is the routine that makes that history look right. New to all of it? Do the one-time setup in [docs/team/START_HERE.md](docs/team/START_HERE.md) first.

## The loop, for every piece of work

**1. Start from the latest `main`, on a new branch.** Branches are named `<your-name>/<topic>`:

```bash
git switch main
git pull
git switch -c siddhartha/time-machine-page
```

**2. Work in small steps, with your agent or without.** Commit whenever something small works:

```bash
git status
git add app/app.py app/templates/article.html
git commit -m "Show an article as it stood at a chosen time"
```

Name the files you add, rather than `git add .`, so nothing unexpected (a password file, a 170 MB build file) slips in. A good commit message says what changed, in the imperative: "Add ...", "Fix ...", "Measure ...".

**3. Check before you push.** If you touched `data/`, `scripts/` or `sql/`, run the build and checks; it must end with `N / N checks passed`:

```bash
python scripts/build_sql.py
python scripts/run_sql.py
```

`run_sql.py` takes the database password from your `.env` file (see [START_HERE](docs/team/START_HERE.md#3-get-the-code-and-build-the-database)), so your agent can run it too. Without the helper: `mariadb -u root -p --table --abort-source-on-error -e "source run_all.sql"`.

If you touched the app or an experiment, run that too and note what you saw.

**4. Log your AI use** in `docs/AI_USE.md`, one line per use, and save the prompt in `docs/prompts/`. See the format at the top of [docs/AI_USE.md](docs/AI_USE.md). It goes in the same pull request as the code it produced.

**5. Push the branch and open a pull request.**

```bash
git push -u origin siddhartha/time-machine-page
gh pr create --fill --reviewer AdnanSN
```

Without the GitHub CLI: after `git push`, open the link it prints (or the repository page, which shows a "Compare & pull request" button). Fill in the template: what changed, how you tested it, what AI you used.

**6. Get one approval, then merge.** Ask a teammate to review. Answer their comments with new commits on the same branch (`git push` again; the pull request updates itself). Once approved, merge it on GitHub with **Squash and merge** or **Create a merge commit**, delete the branch, and update your own `main`:

```bash
git switch main
git pull
```

Never push to `main` directly, and never merge your own pull request without an approval. If `main` moved while you worked, bring your branch up to date before merging:

```bash
git switch main
git pull
git switch siddhartha/time-machine-page
git merge main
```

## Reviewing a teammate's pull request

Reviews count for the process grade, so do them properly and within a day. On the pull request, open **Files changed** and check:

- Does it do what the task in [docs/PLAN.md](docs/PLAN.md) asks, and nothing unrelated?
- Did they run the checks, and is CI green (the tick next to the commit)?
- Is the AI use logged, and does the README still tell the truth?
- Would you be able to explain this code? If not, ask, in a comment on the line.

Then **Review changes**: **Approve**, or **Request changes** with what is missing. To try it yourself: `gh pr checkout <number>`.

## Every week, before the meeting

- Fill in your row in the week's file in [docs/self-assessment/](docs/self-assessment/): work done, hours, links to your commits and pull requests, plan for next week, AI tools used, blockers. It must match the git history.
- Make sure `docs/AI_USE.md` has every AI use of the week.
- Update the status column in [docs/PLAN.md](docs/PLAN.md) for your milestone, in a pull request.

## When you are stuck

Say so in the team chat the same day, with what you tried and the exact error. For anything that should stay on record (a bug, a question about the design), open a GitHub issue instead, so it is part of the project's history.
