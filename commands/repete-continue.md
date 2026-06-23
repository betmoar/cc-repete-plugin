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
   - `session_id` → `""` (see the note under *Resuming from a new session* below — if you are
     continuing in a fresh chat, blanking this is what keeps the loop alive)
   Clear `.repete/transition.md` (truncate it).
5. Begin working the new loop's exit goal immediately, same rules as before.

## status: paused-context — you just /clear-ed, rehydrate and resume

The loop paused because the transcript crossed `context_budget_lines`. Before pausing, the
hook had you write a handoff snapshot of in-flight state to `.repete/handoff.md` — though it
may be absent or empty if that write failed (the hook emits a warning in that case) or if this
is an older loop. The user has (or should have) run `/clear`. Rebuild a fresh working context
from externalized state ONLY — do not rely on conversation memory:

1. Read, in order: `.repete/handoff.md` (the previous session's in-flight snapshot — done /
   in-flight / next step / open questions; may be absent/empty per above, in which case rely on
   the durable state below),
   `.repete/MISSION.md`, the body of `.repete/loop.local.md`, `.repete/constitution.md`
   (the user's hard invariants), `.repete/todo-next.md`, the relevant cards in
   `.repete/lessons/`, and `git log --oneline -15`. If the `remember` plugin is active, also
   read `.remember/now.md`.
2. Give the user a 5-line situation report: mission, current loop's exit goal, what's done,
   what's pending (lead with the handoff's "next concrete step"), last commits.
3. Update frontmatter atomically: `status` → running (leave `phase`/`iteration` as-is) and
   `session_id` → `""` (mandatory here — you have just `/clear`-ed; see *Resuming from a new
   session* below for why). Then resume working this loop's exit goal. The hook will pick the
   loop back up on your next Stop.

## status: paused-max — the iteration cap tripped

Tell the user how many iterations ran and what's still incomplete. Ask whether to (a) raise
`max_iterations` and resume (set it higher, `status` → running, blank `session_id` per the note
below, continue), or (b) treat the current state as a checkpoint and `/repete-cancel`. Do what
they choose.

## status: running or active:false / no loop

If `active:false` or no `.repete/loop.local.md`: tell the user there is no paused loop;
suggest `/repete` to start one or `/repete-status`. If `status: running`, the loop is live —
nothing to continue; suggest `/repete-status`.

## Resuming from a new session — always blank `session_id`

Whenever you set `status` → running from *any* paused state, also set `session_id` → `""` if
there's any chance you're continuing in a different session than the one that started the loop
(a fresh chat, a post-`/clear` window, a new day). The Stop hook stamps `session_id` on first
sight and then ignores Stops from any other session (isolation guard) — so a stale id from the
old session makes the hook silently skip the resumed one and the loop looks dead. Blanking it
lets the hook re-stamp the current session on the next Stop. It's mandatory after `paused-context`
(you've just `/clear`-ed) and the safe default for every other resume; harmless when you happen
to be in the original session.
