---
name: repete-loops
description: >-
  Everything about running an agent in an autonomous loop with the cc-repete plugin —
  deciding whether to loop at all (repete vs. ralph vs. one-shot), writing a mission goal
  the engine can actually verify, layering the constitution / brief / lesson library
  against context rot, reading the checkpoint and budget yields, and debugging a loop that
  is stuck, silent, or spinning. Use this whenever the user runs or mentions /repete,
  /repete-continue, /repete-status, /repete-cancel, a ".repete/" directory, a mission goal,
  `<repete-done>` or `<repete-checkpoint>`, the `rp[3/25]` statusline, a lesson library, a
  gauntlet run — and equally when they are weighing "should I loop this", ask about
  autonomous/agentic loops, iteration harnesses, ralph loops, context rot, or a long
  unattended run, even with no tool named. The two failure modes this skill exists to
  prevent are a vague mission goal producing a runaway loop and a stuck loop being
  misdiagnosed, so reach for it before the first iteration and again the moment one
  misbehaves.
---

# repete loops

repete turns Claude Code's `Stop` hook into a loop engine. When a loop is active, every
attempt to stop is intercepted and the hook decides: tear down (mission verifiably done),
yield to the human (checkpoint or safety budget), or block the stop and re-inject the
working brief (keep going). That single decision is the whole product. Commands, templates,
and this skill exist to set it up, steer it, or explain it.

This skill covers the full arc — should you loop, how to set one up, how to operate it, and
what to do when it misbehaves. Work top-down: the sections are ordered by the moment you're
in, not by topic.

**Plugin root.** Templates and hooks referenced here live under `${CLAUDE_PLUGIN_ROOT}` —
`templates/`, `hooks/stop-hook.sh`, `hooks/promote.sh`. The loop's *state* is separate and
per-project: `.repete/` in the project root, git-ignored by `/repete`.

## 1. Should this be a repete loop at all?

Answer this honestly before scaffolding, including when the answer sends the user elsewhere.
A loop that shouldn't exist costs more than the conversation it replaced.

Loops earn their complexity when work is **iterative, long, and has a checkable end state**:
migrations (N files, one transform), test-until-green, broad sweeps and audits, "keep going
until this command exits 0". They are the wrong tool when:

- **One good agent turn does it.** A loop then adds a Stop hook, state files, and failure
  modes for nothing.
- **There is no verifiable completion state.** A loop with a vibe goal cannot terminate
  honestly — it runs to its cap or fakes done. If you can't name the world-fact that means
  finished, the user needs *planning*, not a loop.
- **Every iteration needs human judgment anyway.** The unattended-iteration advantage
  evaporates and you've added ceremony to a conversation.

### repete vs. ralph vs. one-shot

Two loop architectures exist and the tradeoff is real, so don't default to repete because
it's the plugin in front of you.

**Single-session re-inject (repete).** The Stop hook blocks the stop and re-injects into the
*same* conversation. Context accumulates across iterations. Cheap, native to an interactive
session, supports human-gated checkpoints — but exposed to rot, because the agent at
iteration 8 reasons over a window holding iterations 1–7's dead-ends.

**Fresh-process (ralph).** An external shell loop (`while :; do claude -p < prompt; done`)
starts a clean process per iteration; only on-disk state survives and gets re-read.
Structurally immune to rot — iteration 30 is as pristine as iteration 1 — but it loses the
interactive session, human gating gets awkward, and it needs an external runner.

A hard constraint decides what's even reachable: **a Stop hook cannot clear its own context,
trigger compaction, or spawn a fresh process.** Its only lever is re-inject-into-same-session
[MEASURED: hook output fields are `decision`/`reason`/`continue`/`systemMessage`/
`hookSpecificOutput` — none reset context]. So "auto-reset every N iterations from inside the
hook" is not a knob repete is hiding; true fresh-process means a second engine.

| Profile | Use | Why |
| --- | --- | --- |
| Supervised, evolving, single-track, checkpoints within tens of K tokens | **repete** | Rot is mitigable at that length; you get checkpoints, an evolving payload, and native UX. |
| Unsupervised, long-haul, hundreds of K tokens, rot-immunity non-negotiable | **ralph** | Only structural immunity survives a set-and-walk-away grind. |
| Genuinely both | repete now, **keep durable state on disk** so a runner stays reachable | The disk-backed state is the runner's prerequisite; you needn't choose up front. |

The deciding question is **supervision**, not preference. If a human is at the boundaries,
repete's soft mitigations suffice and you keep the richer UX. If nobody is watching across
hundreds of K tokens, only a fresh process holds up — say so and point at ralph.

The rot evidence behind these thresholds, and the memory-layering pattern that follows from
it, is in **`references/context-rot.md`**. Read it when setting `context_budget_lines`, when
a user asks *why* the loop pauses to `/clear`, or when designing a harness that isn't repete.

## 2. The one rule that matters most: a verifiable mission goal

The mission goal is the exact string the agent must echo inside `<repete-done>…</repete-done>`
to end the run. The hook matches it **exactly**, whitespace-normalized. Two consequences pull
in opposite directions:

- **A vibe goal never terminates correctly.** "Improve the auth flow", "make the tests
  better", "refactor the parser" — no fact exists for the agent to check, so it can't
  honestly claim done and burns the budget instead.
- **A checkable goal ends the run cleanly.** "All tests in `tests/auth/` pass", "`GET /health`
  returns 200 with `{status:\"ok\"}`", "every `.js` under `src/` has a matching `.test.js`".
  The agent reads the world, confirms, echoes the string verbatim, and the hook tears down.

When a user hands you a vibe, convert it *with them* before scaffolding. The question that
does the work: **"How would we know, by looking at the repo or running a command, that this
is done?"** The answer is the mission goal.

Make it **echo-able**, too. "All tests green" invites paraphrase ("tests are passing");
"`npm test` exits 0" is mechanical. The strictness fails in the safe direction — a paraphrase
burns iterations rather than tearing the loop down early — but it still wastes budget, and a
mismatch is no longer silent: the hook counts it (`stale_count`), tells the agent in the next
re-inject exactly why the claim was rejected, and after `stale_limit` consecutive mismatches
yields `paused-stale` to the human rather than grinding to the cap.

## 3. Setting up a run

`/repete` does the scaffolding. Your job is the judgment it can't have:

1. **Mission goal** — the verifiable statement above. The one thing you may not let stay vague.
2. **This loop's exit goal** — the narrower thing the *first* loop reaches before checkpointing.
   Usually "produce a plan + do the first slice", not the whole mission.
3. **Constitution** — `.repete/constitution.md`, the frozen invariants. Offer to seed it from
   hard rules the user states; don't force a prompt, many loops have none.
4. **Optional features** — all four default OFF. Offer once, briefly. See below.
5. **Budgets** — suggest defaults, confirm only if the user cares.

Then restate the mission goal, this loop's exit goal, the budgets, and the exit sentinels in
a few lines, and **start working the exit goal immediately**. The loop auto-continues on each
Stop until a sentinel fires or a budget trips.

### The four memory layers — what goes where

Each iteration's re-inject is assembled in this order: **evolving brief → lessons catalog →
user constitution → engine protocol (last)**. You author three; the protocol is the engine's.
Putting content in the wrong layer is the second most common mistake after a vague goal.

| Layer | File | Belongs here | Does NOT |
| --- | --- | --- | --- |
| **Evolving brief** | `.repete/loop.local.md` body | *This loop's* exit goal + working brief, priority-ordered, real paths. Changes every checkpoint. | The whole mission (that's MISSION.md). Hard invariants (constitution). Lesson bodies. |
| **User constitution** | `.repete/constitution.md` | Frozen invariants for the whole run: don't-touch dirs, "keep the public API stable", the exact test command, commit conventions. | Anything that changes between loops. Anything the engine already enforces. |
| **Lessons** | `.repete/lessons/*.md` | One card per dead-end, in template format. The hook injects a *catalog* (metadata only); the agent reads bodies on demand. | Card bodies pasted into the brief — that re-injects them every iteration, the exact rot the catalog design eliminates. |
| **Engine protocol** | `templates/protocol.md` (hook-owned) | Nothing. The hook `cat`s it verbatim and substitutes `${PHASE}`/`${NEXT}`. | Editing it — unsupported; the hook never validates your version and dropped placeholders go silently unfilled. |

The governing principle: **the constitution is what must stay true the entire run; the brief
is what to do right now.** A rule that still applies three loops from now is a constitution
rule.

Constraints live in **one** place — `.repete/constitution.md`. MISSION.md's Constraints
section is a pointer to it, deliberately: two files both holding "constraints" is a desync
surface. Keep the constitution short and internally consistent (under ~40 lines combined with
the protocol). Adherence degrades with rule *count and mutual conflict*, not with repetition —
so a tight conflict-free constitution re-injected every iteration keeps the loop on the rails,
while a sprawling contradictory one quietly erodes it.

### Optional features — off by default

Four frontmatter flags in `loop.local.md` gate behavior that is **off by default**, because
each adds re-injected text or removes a safety gate:

- **`lessons_enabled`** — injects the lessons catalog each iteration and adds a "write a card
  on every dead-end / consult the catalog" rule. Worth it for a long mission that should
  accrete a reusable library; noise for a short loop. Off → no catalog, no card-writing
  instruction, and `/repete` doesn't scaffold `.repete/lessons/`.
- **`todo_next_enabled`** — adds "log out-of-scope finds to `todo-next.md`" and scaffolds the
  file. Turn it on when harvesting a backlog *is* part of the point.
- **`autonomous`** — removes the checkpoint gate; see below.
- **`gauntlet`** — builder/critic rounds against a reference; see **`references/gauntlet.md`**.
  Only meaningful when a concrete example of "great" exists.

The default-off stance is the answer to "the loop is too chatty": a bare loop re-injects only
the brief + constitution + the frozen core protocol. Nothing tells it to journal.

### Autonomous mode

`autonomous: true` removes the **checkpoint gate**: no `<repete-checkpoint>`, no pause at each
per-loop exit goal. The loop works toward the mission and stops only on `<repete-done>` or a
budget. Three things to design for:

1. **Use a coarse exit goal.** With no checkpoint gate the per-loop exit goal stops being a
   pause point, so set it ≈ the mission goal, or the next big slice. A narrow one is harmless
   but pointless.
2. **Pair it with a non-zero `max_iterations`.** Autonomous with both budgets at 0 has no
   backstop you chose. The hook self-heals rather than allowing that (it stamps a safety cap —
   see §6), but a cap you picked beats one the engine picked for you.
3. **The context gate still fires.** A Stop hook cannot `/clear` itself, so even an autonomous
   loop pauses at `context_budget_lines` for a human `/clear` + `/repete-continue`. Autonomy
   removes the *checkpoint* gate, not the *context* gate — budget the run accordingly.

## 4. Operating a live loop

### The statusline

With the cc-status plugin composing statuslines, repete renders a segment — read it before
asking the user what state they're in:

| Render | Means |
| --- | --- |
| `rp[3]` | Iteration 3, uncapped (`max_iterations: 0`). |
| `rp[3/25]` | Iteration 3 of 25. |
| `rp[7/25] ·ck` | Paused at a checkpoint — waiting on `/repete-continue`. |
| `rp[7/25] ·ctx` | Paused on the context budget — needs `/clear` then `/repete-continue`. |
| `rp[25/25] ·max` | Iteration cap tripped. |
| `rp[4/25] ·stale` | Repeated done-claims didn't match the goal. |
| *nothing* | No active loop in this project (or no `.repete/loop.local.md`). |

A `running`/`summarizing` loop renders plain, with no marker. `/repete-status` gives the full
picture — phase, iteration, goal, budgets, pending TODOs, lessons.

### Reading the yields

The loop hands control back in five situations. Diagnose which one before acting:

- **`paused-checkpoint`** — this loop's exit goal was met and a next payload is proposed in
  `.repete/transition.md`. Review and edit it, sanity-check against MISSION.md for drift, then
  `/repete-continue` promotes it (mechanically, via `hooks/promote.sh`) and starts the next
  loop. This is the normal boundary and where you steer.
- **`paused-context`** — the transcript crossed `context_budget_lines`. This is the anti-rot
  valve and it's a *two-step* yield you don't drive by hand: on the first over-budget Stop the
  hook flips to a transient `summarizing` status and spends one turn having the agent write a
  handoff snapshot (done / in-flight / next step / open questions) to `.repete/handoff.md`; on
  the next Stop it pauses. Run `/clear`, then `/repete-continue` rehydrates a fresh context
  **from disk only** — handoff first, then MISSION.md, the loop body, todo-next, lessons, git
  log — never from the wiped conversation. A present, non-empty handoff makes the restart
  *lossless* rather than merely clean. If the write failed the hook warns and rehydrate leans
  on durable on-disk state — still clean, the uncommitted delta lost, which is exactly why you
  keep progress on disk every iteration.
- **`paused-max`** — the iteration cap tripped. Raise `max_iterations` and resume, or treat
  the state as a checkpoint and `/repete-cancel`. **Repeatedly hitting this means the mission
  goal is probably a vibe** — go back to §2 rather than raising the cap again.
- **`paused-stale`** — `stale_limit` consecutive `<repete-done>` claims failed the goal match.
  Each one already carried an explanatory note in the re-inject, so reaching the limit means
  the agent kept mis-claiming. Two causes: the goal string is wrong (fix `mission_goal` in
  `loop.local.md` **and** `GOAL:` in MISSION.md — they must agree), or the work truly isn't
  done and the loop was spinning on a false claim. `/repete-continue` resets the count.
- **mission done** — the goal string matched; the hook set `active: false`. Finished.

A checkpoint always beats a done sentinel in the same message: the human-gated path is the
safe one, so an accidental co-occurrence never tears the loop down.

### Budgets — sane defaults

- **`max_iterations`** — the runaway backstop. `0` is uncapped; warn when a user asks for it.
  For a supervised single-track mission, single digits to low tens between checkpoints.
- **`stale_limit`** — consecutive mismatched done-claims before `paused-stale` (default 3, `0`
  disables). Spin detection on the cheapest available signal. Below the limit each mismatch
  gets a re-inject note explaining the rejection, so most loops self-correct on the next turn
  with no human involvement.
- **`context_budget_lines`** — raw transcript JSONL lines, a loose proxy for context size, not
  tokens (default 2500). A loop reading large files rots faster than the line count implies,
  so don't treat the budget as the only rot signal: if output quality degrades first,
  checkpoint and rehydrate by hand. Keep durable progress on disk *every* iteration — update
  the loop body, append to `todo-next.md`, write lesson cards, commit — so the handoff only
  carries the small uncommitted residual and even a missing snapshot loses nothing that
  mattered.

### Authoring lesson cards

When `lessons_enabled`, the loop writes a card to `.repete/lessons/NNN-slug.md` per dead-end
(format in `templates/lesson-card.md`):

```
---
slug: <short-kebab-slug>
tags: [<area>, <tool>, <symptom>]   # how the catalog decides what to surface
severity: low | medium | high       # how badly it bit
hits: 1                             # bump (don't duplicate) when it recurs
created: <YYYY-MM-DD>
---
**Situation:** <the trigger conditions>
**Tried:** <what was attempted>
**Outcome:** <what actually happened>
**Rule:** <the imperative takeaway for next time>
```

Two habits keep the library from rotting:

1. **Distill, don't journal.** The card stores the *rule*, not the transcript — retrievable
   and short. A distilled lesson beats a pasted trace by a wide margin.
2. **Dedup by bumping `hits`.** When a lesson recurs, increment the existing card instead of
   adding a near-duplicate. The catalog ranks by `severity` then `hits`, so dedup is what
   surfaces the lessons that actually bite; a never-deduped library is flat at `hits:1`.

The agent retrieves on demand: the hook injects one line per card and the agent `Read`s only
the cards whose tags match what it's about to do. Bulk-reading them is the rot the catalog
exists to prevent.

## 5. Gauntlet runs

`gauntlet: true` turns iterations into reference-driven builder/critic rounds — the pattern
for raising an artifact to an ambitious quality bar when a concrete example of "great" exists.
It needs **both** `reference:` and `bar:` filled; the hook withholds the rules when either is
empty, because a gauntlet with nothing to A/B against is iteration-burning theater.

The round discipline, the critic-packet hygiene that decides whether these runs work, and how
gauntlet composes with the budgets are in **`references/gauntlet.md`**. Read it before
enabling the flag or when a user's gauntlet run isn't converging.

## 6. Debugging a loop that misbehaves

Symptom-first. Most reports are one of these.

**"The loop does nothing — Stop just works normally."** In order: is there a
`.repete/loop.local.md`? Is `active: true`? Is `status` one of the terminal/paused values
(`done`, `cancelled`, `paused-*`) — those exit early by design? Is `jq` on PATH? And the one
that looks most like a dead loop: **`session_id` mismatch.** The hook stamps the session id on
first sight and then ignores Stops from any other session, so a state file carrying a stale id
makes the loop invisible in the current session. Every `/repete-continue` resume path blanks
`session_id` for exactly this reason; if someone resumed by hand-editing, blank it.

**"It warned about jq once and now it's silent."** Missing `jq` means the hook can't steer, so
it fails open (exit 0, Stop passes) — but an *active* loop gets one hand-built warning first,
marked by `.repete/.warned-nojq` so it fires once per `.repete/` rather than every Stop.
Nothing clears that marker automatically; delete the file to hear it again.

**"It says `max_iterations: 25` and I never set that."** That's the backstop. Any active loop
running with **both** `max_iterations` and `context_budget_lines` at 0 gets a safety cap of 25
stamped into state with a one-time warning — including gated loops, because a gated loop whose
agent never checkpoints has no other mechanical stop. Set your own cap to override it.

**"The agent clearly said `<repete-done>` and nothing happened."** Compare the emitted string
to `mission_goal` character by character — the match is exact after whitespace normalization,
so a rephrase, a trailing period, or smart quotes all miss. Check `stale_count`: if it's
climbing, the hook saw the claim and rejected it (working as designed, and the agent is being
told why). If it stays 0, the hook didn't see a sentinel at all.

**"State looks wrong / was hand-edited."** `fm()` reads the **first** occurrence of a key in
the first frontmatter block, so a duplicated key silently uses the earlier one. A UTF-8 BOM or
a missing closing `---` are both handled, but a second copy of a key is not. Check for
duplicates before anything else.

**"A message claimed a pause/teardown but state didn't change."** The hook refuses to announce
an outcome it couldn't persist: on a failed write it warns that state could not be saved,
takes no decision, and lets the Stop through. So that combination means the write failed —
check whether `.repete/` is writable and whether the disk is full.

**Never edit `stale_count`, `iteration`, `phase`, or `status` by hand to "fix" a loop.** They
are hook-maintained; use `/repete-continue` (which resets what needs resetting) or
`/repete-cancel`. The exception is `mission_goal` — fixing a wrong goal string is a legitimate
hand edit, and it must be changed in `loop.local.md` and MISSION.md together.

## Reference files

- **`references/context-rot.md`** — the measured evidence behind the rot thresholds and the
  memory-layering architecture. Read when setting `context_budget_lines`, explaining *why* the
  loop pauses, or designing a non-repete harness.
- **`references/gauntlet.md`** — the builder/critic round discipline, critic-packet hygiene,
  and what the hook does vs. what the agent does. Read before enabling `gauntlet`.
