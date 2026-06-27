---
name: running-repete-loops
description: >-
  Operate a cc-repete autonomous loop well — write a verifiable mission goal,
  set up the frozen constitution vs. the evolving brief, author lesson cards,
  read checkpoints, and tune budgets. Use this whenever the user is starting,
  configuring, resuming, or debugging a repete run (the /repete, /repete-continue,
  /repete-status, /repete-cancel commands), mentions a "repete loop", an
  autonomous/self-evolving loop, a ".repete/" directory, a mission goal, loop
  checkpoints, context-rot pauses, or a lesson library — even if they don't name
  the plugin explicitly. The single biggest failure mode is a vague mission goal
  producing a runaway loop, so reach for this skill before the first iteration runs.
---

# Running repete loops

repete is an autonomous loop engine: a `Stop` hook re-injects the current loop payload each
time the agent tries to stop, so the agent iterates toward a goal unattended, yielding to the
human only at checkpoints and safety budgets. This skill is about operating that engine *well*.
The mechanics are in the hook; the judgment is here.

The whole system lives or dies on one thing: **a mission goal that is a checkable state of the
world.** Everything else is downstream of that. Get it right and the loop terminates cleanly;
get it wrong and the loop either spins to its iteration cap or declares a false victory.

## The one rule that matters most: a verifiable mission goal

The mission goal is the exact string the agent must echo inside `<repete-done>…</repete-done>`
to end the whole run. The hook does an **exact match** (whitespace-normalized) against the
stored `mission_goal`. Two consequences follow, and they pull in opposite directions:

- **If the goal is a vibe, the loop never terminates correctly.** "Improve the auth flow",
  "make the tests better", "refactor the parser" — none of these are a state the hook (or the
  agent) can check. The agent can't honestly emit `<repete-done>` because there's no fact to
  verify, so it runs to `max_iterations` and burns the budget.
- **If the goal is checkable, the loop knows when it's done.** "All tests in `tests/auth/`
  pass", "`GET /health` returns 200 with `{status:\"ok\"}`", "every `.js` file under `src/`
  has a corresponding `.test.js`". These are facts. The agent reads the world, confirms the
  fact, emits the goal string verbatim, and the hook tears the loop down.

When helping a user define a mission, push hard on this. If they hand you a vibe, convert it
into a checkable state *with them* before scaffolding anything. Ask: "How would we know, by
looking at the repo or running a command, that this is done?" The answer is the mission goal.

A good goal is also **stable** — it shouldn't be a string the agent might paraphrase. "All
tests green" is risky (the agent might write "tests are passing"); "`npm test` exits 0" is
better because it's mechanical. The brittle failure direction is *burns the full budget*, not
*exits early* — the hook is deliberately strict so an accidental paraphrase never tears the
loop down prematurely. That's the safe direction to err, but it still wastes iterations, so
make the goal echo-able.

## The four memory layers — what goes where

Each iteration's re-inject is assembled from four layers, in this order: **evolving brief →
lessons catalog → user constitution → engine protocol (last)**. You author three of them
(the protocol is the engine's own, hook-owned). Putting content in the wrong layer is the
second most common mistake, so be deliberate:

| Layer | File | What belongs here | What does NOT |
| --- | --- | --- | --- |
| **Evolving brief** | `.repete/loop.local.md` body | *This loop's* exit goal + working brief, in priority order, referencing real paths. Changes every checkpoint. | The whole mission (that's MISSION.md). Hard invariants (that's the constitution). Lesson bodies. |
| **User constitution** | `.repete/constitution.md` | Frozen invariants for the *whole run*: don't-touch dirs, "keep the public API stable", "run tests with `pnpm test`", "commit every iteration", conventions. | Anything that changes between loops. Anything mechanical the engine already enforces. |
| **Lessons** | `.repete/lessons/*.md` | One card per mistake/dead-end, in the template format. The hook injects a *catalog* (metadata only); the agent reads card bodies on demand. | Don't paste card bodies into the brief — that re-injects them every iteration and is the exact context-rot source the catalog design eliminates. |
| **Engine protocol** | `templates/protocol.md` (hook-owned) | Nothing — it's repete's own loop protocol. The hook `cat`s this file verbatim each iteration and substitutes `${PHASE}`/`${NEXT}`, so it's engine-owned, not something to author here. | Editing it is unsupported: the hook never validates your version, and dropped placeholders silently go unfilled. |

The governing principle: **the constitution is for things that must stay true the entire run;
the brief is for what to do right now.** If a rule would still apply three loops from now, it's
a constitution rule. If it's "this loop, do X", it's the brief.

### The constitution vs. MISSION.md Constraints

Constraints live in **one** place: `.repete/constitution.md`. MISSION.md's Constraints section
is just a pointer to it. This is deliberate — two files both holding "constraints" is a desync
surface where the user edits one and forgets the other. Author hard invariants in the
constitution; leave MISSION.md as the human-readable narrative.

Keep the constitution **short and internally consistent** — under ~40 lines combined with the
protocol. Instruction adherence degrades with rule *count and mutual conflict*, not repetition,
so a tight conflict-free constitution that re-injects every iteration helps the loop stay on
the rails; a sprawling contradictory one quietly erodes adherence.

## Optional features — off by default

Three frontmatter flags in `loop.local.md` gate behavior that is **off by default**, because each
adds re-injected text or removes a safety gate. Turn them on deliberately, not reflexively:

- **`lessons_enabled: false`** — when on, the hook injects the lessons catalog each iteration and
  the protocol gains a "write a lesson card on every dead-end / consult the catalog" rule. Worth it
  for a long mission that should accrete a reusable lesson library; pure noise for a short loop.
  Off → no catalog, no card-writing instruction, and `/repete` doesn't scaffold `.repete/lessons/`.
- **`todo_next_enabled: false`** — when on, the protocol gains a "log out-of-scope finds to
  `todo-next.md`" rule and `/repete` scaffolds the file. Off → the agent isn't told to journal
  side-quests, so it stays focused on the exit goal. Turn it on when harvesting a backlog *is* the
  point.
- **`autonomous: false`** — see below.

The default-off stance is the fix for the loop being too chatty: a bare loop re-injects only the
brief + constitution + the frozen core protocol (re-read, constitution, the `<repete-done>`
sentinel, and — in gated mode — the `<repete-checkpoint>` rule). Nothing instructs it to journal.

### Autonomous mode

`autonomous: true` removes the **checkpoint gate**: the loop no longer emits `<repete-checkpoint>`
or pauses for `/repete-continue` at each per-loop exit goal — it keeps working toward the *mission*
and only stops on `<repete-done>` (mission verifiably true) or `max_iterations`. Use it for an
unsupervised run where you don't want to approve every sub-boundary.

Two consequences to design for:

1. **Use a coarse exit goal.** With no checkpoint gate, the per-loop exit goal stops being a
   pause point, so in practice set it ≈ the mission goal (or just the next big slice). A narrow
   exit goal in autonomous mode is harmless but pointless.
2. **The context gate still fires.** A Stop hook cannot `/clear` itself (see
   `designing-autonomous-loops` on the hook-spine constraint), so even an autonomous loop still
   pauses at `context_budget_lines` for a human `/clear` + `/repete-continue`. Autonomy removes the
   *checkpoint* gate, not the *context* gate — budget your run accordingly.

## Authoring lesson cards

When the loop hits a mistake, dead-end, or a fix that didn't work, it writes a lesson card to
`.repete/lessons/NNN-slug.md`. The format (from `templates/lesson-card.md`):

```
---
slug: <short-kebab-slug>
tags: [<area>, <tool>, <symptom>]   # how the catalog decides what to surface
severity: low | medium | high       # how badly it bit
hits: 1                              # bump (don't duplicate) when it recurs
created: <YYYY-MM-DD>
---
**Situation:** <the trigger conditions>
**Tried:** <what was attempted>
**Outcome:** <what actually happened>
**Rule:** <the imperative takeaway for next time>
```

Two things make the lesson library work instead of rotting:

1. **Distill, don't journal.** The card stores the *rule*, not the transcript. "Reflect briefly:
   what you tried, what happened, the rule for next time." A distilled lesson is worth far more
   than a pasted trace — it's retrievable and it's short.
2. **Dedup by bumping `hits`.** If a lesson recurs, find the existing card and increment `hits`
   rather than adding a near-duplicate. The catalog ranks by `severity` then `hits`, so
   diligent dedup is what surfaces the lessons that actually bite most. A never-deduped library
   ranks everything `hits:1` and the signal is flat.

The agent retrieves cards on demand: the hook injects a one-line-per-card catalog, and the
agent `Read`s only the cards whose tags match what it's about to do. Don't bulk-read them all —
that's the rot the catalog exists to prevent.

## Reading checkpoints and the safety yields

The loop hands control back to the human in four situations. Recognize which one you're in:

- **`paused-checkpoint`** — the loop hit *this loop's* exit goal and proposed a next payload in
  `.repete/transition.md`. Review/edit it, sanity-check it against MISSION.md for drift, then
  `/repete-continue` to promote it and start the next loop. This is the normal evolving-loop
  boundary and where you steer.
- **`paused-context`** — the transcript crossed `context_budget_lines`. This is the anti-rot
  valve, and it's a *two-step* yield you don't have to drive manually: on the first
  over-budget Stop the hook flips to a transient `summarizing` status and spends one turn
  having the agent write a handoff snapshot of in-flight state (done / in-flight / next step /
  open questions) to `.repete/handoff.md`; on the next Stop it pauses. Run `/clear`, then
  `/repete-continue` rehydrates a fresh context **from disk only** — reading `handoff.md`
  first, then MISSION.md, the loop body, todo-next, lessons, git log — not from the wiped
  conversation. When the handoff is present and non-empty it makes the restart lossless rather
  than just clean: the in-flight delta survives the wipe. If the agent fails to write it the
  hook warns and rehydrate leans on the durable on-disk state instead — still clean, but the
  uncommitted delta is lost, which is exactly why you keep progress on disk every iteration
  (see Budgets below). `/repete-continue` also blanks `session_id` so the loop reattaches to
  the post-`/clear` session.
- **`paused-max`** — the iteration cap tripped. Either raise `max_iterations` and resume, or
  treat the current state as a checkpoint and `/repete-cancel`. If you keep hitting this, the
  mission goal is probably a vibe — go back and make it checkable.
- **mission done** — the agent emitted `<repete-done>GOAL</repete-done>` matching the goal; the
  hook set `active:false`. Finished.

A checkpoint always wins over a done sentinel in the same message — the human-gated path is the
safe one, so an accidental co-occurrence never tears the loop down.

## Budgets — sane defaults

- **`max_iterations`** — the runaway backstop. `0` is uncapped; warn the user if they ask for
  it. For a supervised single-track mission, single digits to low tens is plenty between
  checkpoints.
- **`context_budget_lines`** — raw transcript JSONL lines, a loose proxy for context size (not
  tokens). Default 2500. When the transcript passes it, the loop pauses for the `/clear`+
  rehydrate cycle above. This is a *coarse* proxy; if a loop reads large files it rots faster
  than the line count implies, so don't treat hitting the budget as the only rot signal —
  if outputs degrade before the budget trips, checkpoint and rehydrate manually.

  The engine asks the agent to snapshot in-flight state to `.repete/handoff.md` when the budget
  trips, so the boundary isn't something to babysit — but treat that snapshot as a thin,
  best-effort safety net, not a guarantee: the write can fail, in which case the hook warns and
  the rehydrate falls back to durable on-disk state. Keep durable progress on disk *every*
  iteration (update the loop body, append to `todo-next.md`, write lesson cards, commit) so the
  handoff only has to carry the small uncommitted residual — then even a missing snapshot loses
  nothing that mattered.

## Scaffolding a new run — the checklist

When the user starts a loop (`/repete`), establish, asking only for what's genuinely missing:

1. **Mission goal** — the verifiable completion statement (see the first section; this is the
   one you cannot let be vague).
2. **This loop's exit goal** — the narrower thing the *first* loop achieves before checkpointing.
   Usually "produce a plan + do the first slice", not the whole mission.
3. **Constitution** — lay down `.repete/constitution.md` from the template; offer to seed it
   from any hard invariants the user states. Don't force a prompt — many loops have none.
4. **Optional features (default OFF)** — offer `lessons_enabled` / `todo_next_enabled` once,
   briefly; enable only what the user wants (see *Optional features* above). Offer `autonomous`
   only for an unsupervised run with a coarse exit goal. Leave all three off otherwise — a quiet
   loop is the default for a reason.
5. **Budgets** — suggest defaults; only confirm if the user cares.

Then restate the mission goal, this loop's exit goal, the budgets, and the two exit signals in
a few lines, and begin working the exit goal immediately. The loop auto-continues on each Stop
until a sentinel fires or a budget trips.
