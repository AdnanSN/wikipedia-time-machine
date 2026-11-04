# Start here

For Siddhartha and Rahmath, and anyone who joins later. It takes about 45 minutes the first time, most of it installing. After that, your coding agent does the heavy lifting, and this repository tells it how we work.

## 1. What we are building, and what is yours

A **Wikipedia time machine**: the full history of 30 Wikipedia articles in one MariaDB table `WITH SYSTEM VERSIONING`, so you can ask "what did this article say on 1 June 2010?" with one clause, `FOR SYSTEM_TIME AS OF`. Read the [README](../../README.md) to see what already works.

Milestone M1, the foundation, is done: the data, the database, the queries and the checks. Your parts are in [docs/PLAN.md](../PLAN.md):

| Who | Milestones | Due |
|-----|------------|-----|
| Siddhartha | **M2**: the web page where you pick an article and a moment and read it as it stood; then **M6**: the diff between two moments | M2 by 17 Nov, M6 by 24 Nov |
| Rahmath | **M3**: how the versioned table grows, and what partitioning by `SYSTEM_TIME` does about it; then **M5**: the same history built with triggers, for comparison | M3 by 17 Nov, M5 by 24 Nov |

**Why the process matters as much as the code:** half of your mark is the process, and the supervisor reads it from the git history. Your work only counts as yours if it arrives in your own commits, through your own pull requests, reviewed by a teammate, with your AI use logged. Your agent will do it that way if you follow the steps below.

## 2. Install the tools (Windows, once)

Open **PowerShell** and run these one at a time:

```powershell
winget install --id Git.Git -e
```

```powershell
winget install --id GitHub.cli -e
```

```powershell
winget install --id Python.Python.3.12 -e
```

Then install:

- **MariaDB Server 12.3**: download the Windows MSI from [mariadb.org/download](https://mariadb.org/download/) and install it. Choose a root password and write it down; keep "Install as service" ticked so the server starts with Windows.
- **Your coding agent**: [Claude Code](https://claude.com/claude-code) (desktop app or terminal) reads this repository's instructions automatically from `CLAUDE.md`. Other agents (Codex, Cursor, Copilot) read `AGENTS.md`, which says the same.

Close PowerShell and open a new one so it finds the new programs. Then tell Git who you are. **Use the email address of your GitHub account**, otherwise GitHub cannot link your commits to you and they will not count as yours:

```powershell
git config --global user.name "Your Name"
```

```powershell
git config --global user.email "the-email-of-your-github-account@example.com"
```

```powershell
gh auth login
```

For `gh auth login`, choose GitHub.com, HTTPS, and log in with a web browser.

## 3. Get the code and build the database

Accept the invitation to the repository first: GitHub sends it by email once Adnan adds you, or open [github.com/AdnanSN/wikipedia-time-machine/invitations](https://github.com/AdnanSN/wikipedia-time-machine/invitations). Then:

```powershell
mkdir $HOME\dev -Force; cd $HOME\dev
```

```powershell
git clone https://github.com/AdnanSN/wikipedia-time-machine.git
```

```powershell
cd wikipedia-time-machine
```

```powershell
copy .env.example .env
```

Open `.env` in a text editor (`notepad .env`) and put your MariaDB root password after `WTM_DB_PASSWORD=`. This file stays on your computer (Git ignores it), and it lets your agent run the database scripts without asking you for the password. Never paste the password into a chat with an agent. Then build the database:

```powershell
python scripts/build_sql.py
```

```powershell
python scripts/run_sql.py
```

It takes about half a minute and must end with `8 / 8 checks passed`. If it does not, send the last 20 lines of the output to the team chat.

## 4. Start your agent

Open Claude Code in the `wikipedia-time-machine` folder (desktop app: choose that folder; terminal: run `claude` inside it) and paste the prompt for your milestone.

**Siddhartha:**

```text
I'm Siddhartha. I'm starting milestone M2 (the time machine page) of this project. First read AGENTS.md, CONTRIBUTING.md and docs/PLAN.md. Then:
1. Check that my setup works: git, gh, Python, and the database (run python scripts/run_sql.py --query "SELECT COUNT(*) FROM wiki_time_machine.article" and expect 30). Help me fix anything that's missing.
2. Create my branch siddhartha/time-machine-page from an up-to-date main.
3. Show me a short plan for M2, split into small steps that each end in a commit, and wait for my OK before writing code.
4. As you work, explain each step in plain words, because I will present this work and must be able to explain every line. Ask me before each commit, log your work in docs/AI_USE.md with this prompt saved in docs/prompts/, and when the first step works, push and open a draft pull request for Adnan to review.
```

**Rahmath:**

```text
I'm Rahmath. I'm starting milestone M3 (growth and partitioning by SYSTEM_TIME) of this project. First read AGENTS.md, CONTRIBUTING.md and docs/PLAN.md. Then:
1. Check that my setup works: git, gh, Python, and the database (run python scripts/run_sql.py --query "SELECT COUNT(*) FROM wiki_time_machine.article FOR SYSTEM_TIME ALL" and expect 13354). Help me fix anything that's missing.
2. Create my branch rahmath/growth-partitioning from an up-to-date main.
3. Show me a short plan for M3, split into small steps that each end in a commit, and wait for my OK before writing code. Put the measurement scripts in experiments/growth/ so they rerun with one command, and repeat every timing at least 5 times.
4. As you work, explain each step in plain words, because I will present this work and must be able to explain every line. Ask me before each commit, log your work in docs/AI_USE.md with this prompt saved in docs/prompts/, and when the first step works, push and open a draft pull request for Adnan to review.
```

From then on, talk to it like a colleague: ask it why, ask it to show you the query, ask it to slow down. You are responsible for everything it writes.

## 5. Your routine

The full version is in [CONTRIBUTING.md](../../CONTRIBUTING.md). In short:

1. One branch per task, named `yourname/topic`, started from the latest `main`. Never commit to `main`.
2. Small commits that each say what changed.
3. A pull request for everything, reviewed by a teammate before it is merged. Review theirs too, within a day.
4. Every AI use logged in `docs/AI_USE.md`, with the prompt saved in `docs/prompts/`, in the same pull request.
5. Before the weekly meeting, fill in your row in `docs/self-assessment/`, with links to your commits and pull requests.

Stuck for more than an hour? Write in the team chat what you tried and the exact error.
