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
  valve. Run `/clear`, then `/repete-continue` rehydrates a fresh context **from disk only**
  (MISSION.md, the loop body, todo-next, lessons, git log) — not from the wiped conversation.
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

## Scaffolding a new run — the checklist

When the user starts a loop (`/repete`), establish, asking only for what's genuinely missing:

1. **Mission goal** — the verifiable completion statement (see the first section; this is the
   one you cannot let be vague).
2. **This loop's exit goal** — the narrower thing the *first* loop achieves before checkpointing.
   Usually "produce a plan + do the first slice", not the whole mission.
3. **Constitution** — lay down `.repete/constitution.md` from the template; offer to seed it
   from any hard invariants the user states. Don't force a prompt — many loops have none.
4. **Out of scope** — what gets logged to `.repete/todo-next.md` instead of chased now.
5. **Budgets** — suggest defaults; only confirm if the user cares.

Then restate the mission goal, this loop's exit goal, the budgets, and the two exit signals in
a few lines, and begin working the exit goal immediately. The loop auto-continues on each Stop
until a sentinel fires or a budget trips.
