# AI-use log

The team guide asks for every use of an AI tool to be traceable: which tool, which part of the work it touched, the prompt, and what it produced. One line per use, newest at the bottom, added in the same pull request as the work it produced. We are responsible for everything we submit, AI-assisted or not.

**How to add an entry**

1. Save the prompt (your words to the tool, plus anything important you added later in the conversation) as `docs/prompts/<date>-<name>-<topic>.md`. Summarise very long conversations, but keep the instructions that shaped the result.
2. Add a row below: date, who, tool and model, the files or part it touched, a link to the prompt file, and the pull request or commits that contain the result.
3. If later work replaces what the AI produced, say so in a new row; do not delete old rows.

| Date | Who | Tool | What it touched | Prompt | Result |
|------|-----|------|-----------------|--------|--------|
| 2026-11-04 | Adnan S | Claude Code (Claude Opus 5.5) | Milestone M1: the data set and its download script, the schema and history load, the demo queries and checks, CI, README, AGENTS.md, CONTRIBUTING.md and the planning docs | [prompt](prompts/2026-11-04-adnan-m1-foundation.md) | Branch `adnan/m1-foundation`, pull request #1 |
