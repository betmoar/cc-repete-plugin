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
- **Flags**: `lessons_enabled`, `todo_next_enabled`, `autonomous` (each on/off). In
  autonomous mode, note the loop runs past checkpoints to the mission (no `<repete-checkpoint>`
  pause).
- **This loop's exit goal** (from the loop body).
- **Budgets**: `max_iterations`, `context_budget_lines`.
- **TODO_NEXT** (only if `todo_next_enabled`): count + the top 3 lines.
- **Lessons** (only if `lessons_enabled`): count + the highest-`severity` / highest-`hits` slugs.
- **Lessons catalog (as the loop sees it)**: only when `lessons_enabled: true` — render the
  same ranked, capped catalog the hook would inject: for each card (excluding `_TEMPLATE.md`)
  show `slug · [tags] · severity · hits`, ranked by severity then hits, capped at
  `lesson_catalog_cap` (default 8) with a `+N more` note if it overflows. This previews exactly
  what rides the re-inject. If `lessons_enabled: false`, print a one-line "lessons disabled — no
  catalog is injected" note instead.
- **Constitution**: report whether `.repete/constitution.md` exists and has real content
  (not just the commented starter); if it is large (well over ~40 lines combined with the
  protocol), warn that long frozen layers degrade adherence (rule count is the killer).
- **What to do next**, mapped from `status`:
  - `running` → loop is live; it will continue on the next Stop.
  - `summarizing` → transient: the hook is having the agent write `.repete/handoff.md`
    before the context-budget pause. Nothing to do — let it finish; it becomes
    `paused-context` on the next Stop. (If it's stuck here with the budget no longer
    exceeded, the next Stop resets it to `running`.)
  - `paused-checkpoint` → `/repete-continue` to approve the next payload.
  - `paused-context` → `/clear` then `/repete-continue`.
  - `paused-max` → `/repete-continue` to raise the cap, or `/repete-cancel`.
  - `done` / `active:false` → finished; `/repete` to start a new run.
