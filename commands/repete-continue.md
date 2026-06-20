---
description: Approve a repete checkpoint (or resume after a context /clear) and continue the loop
argument-hint: [optional note / edits to fold into the next payload]
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
---

# Continue a repete loop

A repete loop is paused and waiting for you. Read `.repete/loop.local.md` frontmatter and
branch on `status`.

User note (optional): **$ARGUMENTS**

## status: paused-checkpoint — a loop boundary, approve the next payload

The previous loop hit its exit goal and proposed a next payload in `.repete/transition.md`.

1. Show the user `.repete/transition.md` and the current `.repete/todo-next.md`. The user
   may have already edited `transition.md`; respect those edits. Fold in any `$ARGUMENTS`.
2. Sanity-check against `.repete/MISSION.md`: is this next loop still serving the mission,
   or has it drifted? If it drifted, say so and propose a correction before proceeding.
3. Do NOT copy lesson cards into the payload body. Lessons are surfaced automatically:
   the hook builds a metadata catalog from `.repete/lessons/` every iteration and the
   agent `Read`s the relevant cards on demand. The new payload's "Known traps" section
   stays a pointer (see the template) — never a content sink.
4. Promote: write the approved payload into the BODY of `.repete/loop.local.md` (replace the
   old body, keep/!update frontmatter). Then update frontmatter atomically:
   - `phase` → +1
   - `iteration` → 1
   - `status` → running
   - `active` → true
   Clear `.repete/transition.md` (truncate it).
5. Begin working the new loop's exit goal immediately, same rules as before.

## status: paused-context — you just /clear-ed, rehydrate and resume

The loop paused because the transcript crossed `context_budget_lines`. The user has (or
should have) run `/clear`. Rebuild a fresh working context from externalized state ONLY —
do not rely on conversation memory:

1. Read, in order: `.repete/MISSION.md`, the body of `.repete/loop.local.md`,
   `.repete/constitution.md` (the user's hard invariants), `.repete/todo-next.md`, the
   relevant cards in `.repete/lessons/`, and `git log --oneline -15`. If the `remember`
   plugin is active, also read `.remember/now.md`.
2. Give the user a 5-line situation report: mission, current loop's exit goal, what's done,
   what's pending, last commits.
3. Set frontmatter `status` → running (leave `phase`/`iteration` as-is). Then resume working
   this loop's exit goal. The hook will pick the loop back up on your next Stop.

## status: paused-max — the iteration cap tripped

Tell the user how many iterations ran and what's still incomplete. Ask whether to (a) raise
`max_iterations` and resume (set it higher, `status` → running, continue), or (b) treat the
current state as a checkpoint and `/repete-cancel`. Do what they choose.

## status: running or active:false / no loop

If `active:false` or no `.repete/loop.local.md`: tell the user there is no paused loop;
suggest `/repete` to start one or `/repete-status`. If `status: running`, the loop is live —
nothing to continue; suggest `/repete-status`.
