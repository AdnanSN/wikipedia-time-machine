# Prompt: M2 – Time Machine Page (Siddhartha, 2026-11-05)

Tool: Antigravity (Google DeepMind) — conversation 09ff7f6d-78bd-4085-ac22-9aac642b01cc

## The prompt I gave the AI

> I'm Siddhartha. I'm starting milestone M2 (the time machine page) of this project.
> First read AGENTS.md, CONTRIBUTING.md and docs/PLAN.md. Then:
> 1. Check that my setup works: git, gh, Python, and the database (run
>    `python scripts/run_sql.py --query "SELECT COUNT(*) FROM wiki_time_machine.article"`
>    and expect 30). Help me fix anything that's missing.
> 2. Create my branch siddhartha/time-machine-page from an up-to-date main.
> 3. Show me a short plan for M2, split into small steps that each end in a commit,
>    and wait for my OK before writing code.
> 4. As you work, explain each step in plain words, because I will present this work
>    and must be able to explain every line. Ask me before each commit, log your work in
>    docs/AI_USE.md with this prompt saved in docs/prompts/, and when the first step
>    works, push and open a draft pull request for Adnan to review.

## What the AI produced

The AI read all three docs, verified the environment (everything passed, including
COUNT=30), noticed and reverted an accidental removal of `--abort-source-on-error`
from `scripts/run_sql.py`, proposed a 5-commit plan for M2, and waited for approval
before writing any app code.

Files produced in this session are tracked in docs/AI_USE.md.
