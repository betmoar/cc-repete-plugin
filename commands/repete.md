---
description: Start a self-evolving autonomous loop (repete) toward a mission goal
argument-hint: [mission goal, or leave blank to define interactively]
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
---

# Start a repete loop

You are setting up a **repete** run: an autonomous loop that iterates toward a mission,
evolving its own payload at each human-gated checkpoint and learning from its mistakes.

The Stop hook (`${CLAUDE_PLUGIN_ROOT}/hooks/stop-hook.sh`) is the loop engine. Your job
here is only to lay down clean state and start iteration 1. The hook does the rest.

## 1. Define the mission with the user

User's opening input: **$ARGUMENTS**

Do NOT skip this. A vague mission produces a runaway loop. Establish, asking the user
only for what is genuinely missing:

- **Mission goal** — a single verifiable completion statement. It must be checkable as a
  state of the world (tests green, endpoint returns X, every file in Y migrated), not a
  vibe. This exact string becomes the `<repete-done>` trigger.
- **This loop's exit goal** — the narrower thing the FIRST loop should achieve before it
  checkpoints. Often "produce a plan + do the first slice", not the whole mission.
- **Out of scope** — what should be logged to `todo-next.md` rather than chased.
- **Constraints** — don't-touch dirs, no push, keep API stable, etc.
- **Budgets** — `max_iterations` (0 = uncapped; warn if so) and `context_budget_lines`
  (default 2500 — counts raw transcript JSONL lines, a loose proxy for context size,
  not tokens; when the transcript passes this the hook first spends one turn writing a
  handoff snapshot to `.repete/handoff.md` (transient `summarizing` status), then pauses
  for a `/clear` + `/repete-continue` rehydrate that reads the handoff first). Suggest
  defaults; only confirm if the user cares.

If the mission is genuinely ambiguous, ask 2–4 sharp questions, then proceed. If it is
already clear from `$ARGUMENTS`, restate your understanding in two lines and continue.

## 2. Scaffold `.repete/`

Create, in the project root:

- `.repete/MISSION.md` — from `${CLAUDE_PLUGIN_ROOT}/templates/MISSION.md`, filled in.
- `.repete/loop.local.md` — from `${CLAUDE_PLUGIN_ROOT}/templates/loop.local.md`. Fill the
  frontmatter:
  - `session_id`: the current session id (read it from the environment if available; else
    leave `""` — the hook will simply skip the isolation check).
  - `mission_goal`: the EXACT goal string, identical to `GOAL:` in MISSION.md.
  - `max_iterations`, `context_budget_lines`: as agreed.
  - `lesson_catalog_cap`: max lesson lines surfaced in the catalog each iteration
    (default 8; 0 = uncapped — only for small projects).
  - `started_at`: output of `date -u +%Y-%m-%dT%H:%M:%SZ`.
  - `status: running`, `active: true`, `phase: 1`, `iteration: 1`.
  Fill the body with this loop's exit goal + working brief.
- `.repete/todo-next.md` — create with a one-line header and nothing else.
- `.repete/lessons/` — create the directory. Copy `${CLAUDE_PLUGIN_ROOT}/templates/lesson-card.md`
  to `.repete/lessons/_TEMPLATE.md` so the format is on hand.
- `.repete/constitution.md` — copy from `${CLAUDE_PLUGIN_ROOT}/templates/constitution.md`.
  This is the user's hard-invariants layer, re-injected each iteration. After copying the
  commented starter, ask the user (once, briefly) whether they have hard invariants to seed
  it (don't-touch dirs, the test command, API-stability, no-push, etc.). If they name any,
  write them in as imperative one-liners and delete the comment block so it activates. If
  they have none, leave the starter as-is (it stays inert until filled). Do NOT force this as
  a blocking prompt — offer it and move on.

If `.repete/loop.local.md` already exists and is `active: true`, STOP and tell the user a
loop is already running (offer `/repete-status` or `/repete-cancel`).

## 3. Confirm, then begin

Print a 4-line summary: mission goal, this loop's exit goal, budgets, and the two exit
signals (`<repete-checkpoint>` for a loop boundary, `<repete-done>` for the mission).
Remind the user this loop will auto-continue on each Stop until one of those fires or a
budget is hit.

Then **start working on this loop's exit goal immediately.** Re-read `.repete/MISSION.md`
and any seeded lessons first. Log out-of-scope finds to `.repete/todo-next.md`. When this
loop's exit goal is met, emit a `<repete-checkpoint>` block with your proposed next-loop
payload and stop — do not declare the mission done unless its goal is verifiably true.
