---
description: Show the current repete loop state — phase, iteration, goal, pending TODOs, lessons
argument-hint:
allowed-tools: Read, Bash, Glob, Grep
---

# repete status

Render the current loop state. Read-only — change nothing.

1. If `.repete/loop.local.md` does not exist: report "no repete loop in this project" and stop.
2. Read `.repete/loop.local.md` frontmatter and body. Read `.repete/MISSION.md`.
3. Count entries in `.repete/todo-next.md` and files in `.repete/lessons/` (excluding `_TEMPLATE.md`).

Present a compact report:

- **Mission goal** and whether it looks met (your read — do not auto-complete it).
- **Phase / iteration**, `status`, `active`.
- **This loop's exit goal** (from the loop body).
- **Budgets**: `max_iterations`, `context_budget_lines`.
- **TODO_NEXT**: count + the top 3 lines.
- **Lessons**: count + the highest-`severity` / highest-`hits` slugs.
- **What to do next**, mapped from `status`:
  - `running` → loop is live; it will continue on the next Stop.
  - `paused-checkpoint` → `/repete-continue` to approve the next payload.
  - `paused-context` → `/clear` then `/repete-continue`.
  - `paused-max` → `/repete-continue` to raise the cap, or `/repete-cancel`.
  - `done` / `active:false` → finished; `/repete` to start a new run.
