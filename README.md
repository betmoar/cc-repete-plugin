# repete

Self-evolving autonomous loops for Claude Code.

`repete` formalizes a Ralph-loop workflow into one plugin: an autonomous iteration loop
that **evolves its own payload** at each human-gated checkpoint (or runs unattended in
`autonomous` mode) and **fights context rot** by turning a transcript-size budget into a
`/clear` + rehydrate checkpoint. Opt-in layers let it **harvest out-of-scope discoveries**
as the seed for the next loop and **learn from its mistakes** into a project lesson library —
both off by default so a bare loop stays quiet. It reuses the
[`remember`](https://github.com/betmoar/cc-remember-plugin) plugin for tiered memory rather than
reinventing it.

This is **v0.2.0** — a single evolving loop with opt-in autonomous mode, opt-in project-local
lessons, mismatch-feedback on done-claims, and opt-in gauntlet (builder/critic) rounds.
Multi-phase mission chaining (v2) and cross-project global learning (v3) build on the
same state model.

## How it works

A `Stop` hook is the loop engine. Every time the agent tries to stop, it makes a four-way
decision:

| Last output contains                                        | Hook does                                                                                           |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `<repete-done>GOAL</repete-done>` matching the mission goal | tears the loop down — **mission complete**                                                          |
| `<repete-done>` NOT matching the mission goal               | counts it (`stale_count`), tells the agent why it was rejected in the re-inject, keeps looping      |
| `<repete-checkpoint>…payload…</repete-checkpoint>`          | writes the proposed payload to `.repete/transition.md` and **yields to you** for approval           |
| neither                                                     | **blocks the stop and re-injects** the current loop payload + standing rules (autonomous iteration) |

By default the loop is **gated**: it pauses at each per-loop exit goal for your approval. Set
`autonomous: true` in `loop.local.md` to drop that gate — the loop then runs past sub-goals
toward the mission and only stops on `<repete-done>` or `max_iterations` (a Stop hook still can't
`/clear` itself, so the context-budget pause below still applies). Either way, a loop with
**both** budgets at 0 gets a safety `max_iterations: 25` stamped with a one-time warning — no
configuration can trap Stop forever.

Three safety yields also stop the autonomous run and hand control back:

- **`max_iterations`** reached → paused; `/repete-continue` to raise the cap.
- **`stale_limit`** (default 3) consecutive `<repete-done>` claims that do NOT match the
  mission goal → paused (`paused-stale`); each mismatched claim already gets an
  explanatory note in the re-inject, so the agent knows to re-read `.repete/MISSION.md`
  and quote the goal exactly. A plain work turn resets the count; `0` disables. This
  catches the cheapest spinning signal — false claims of done — before iterations burn.
- **`context_budget_lines`** exceeded → the engine first spends one turn writing a handoff
  snapshot of in-flight state to `.repete/handoff.md` (transient `summarizing` status), then
  pauses; `/clear` then `/repete-continue` rehydrates a fresh context from `.repete/` state —
  reading the handoff first. When that snapshot is present the restart is **lossless**; if the
  agent fails to write it the hook warns and rehydrate falls back to durable on-disk state
  (committed work, git, the loop body) — still clean, but uncommitted in-flight detail may be
  lost. This is the anti-context-rot mechanism. The budget counts raw transcript JSONL lines
  (a loose proxy for context size, not tokens), default 2500.

So: iterations run unattended; **you are only in the loop at transitions** — exactly where
drift and bad decisions compound.

## Gauntlet mode (opt-in): builder/critic rounds against a reference

`gauntlet: true` (with `reference:` — a concrete example of "great" — and `bar:` — one line
naming what "reached the bar" means; the hook withholds the rules if either is empty) turns
iterations into reference-driven improvement
rounds. The hook injects the working rules; the **agent** runs the pattern with subagents:

1. Split the artifact into the smallest independently judgeable parts (`.repete/parts.md`).
2. One builder subagent per part — part, criterion, file paths, nothing else.
3. Every round: ONE fresh-context critic that blind-compares this round vs. the previous
   (`git show`, unlabeled) against the reference and names the single largest gap.
   Verdict → `.repete/critique.md`; its first line rides the next re-inject.
4. The gap is the next round's top priority; when every part meets the bar, one final
   integration critic over the whole artifact precedes any `<repete-done>` claim.

The loop engine is untouched — no new exit paths, fail-open preserved; a critic never gates
the done sentinel, and subagent sentinels were already ignored. Rounds stop on the existing
budgets (`max_iterations` = rounds, `context_budget_lines`, `stale_limit`) or when you stop
the run.

## Commands

| Command            | Purpose                                                            |
| ------------------ | ------------------------------------------------------------------ |
| `/repete [goal]`   | Define the mission, scaffold `.repete/`, start iteration 1         |
| `/repete-continue` | Approve a checkpoint's next payload, or rehydrate after a `/clear` |
| `/repete-status`   | Read-only view of phase, iteration, goal, pending TODOs, lessons   |
| `/repete-cancel`   | Deactivate the loop (state preserved for review)                   |

## Skills

The plugin bundles two skills (auto-discovered, no install step) that carry the
operational and design judgment, so the commands stay terse:

- **running-repete-loops** — *operate* a repete loop well: writing a verifiable
  mission goal, the four memory layers (what goes where), authoring lesson cards,
  reading the checkpoint/budget states, sane defaults. Reach for it whenever you
  start, resume, or debug a run.
- **designing-autonomous-loops** — *decide* whether and how to loop at all:
  single-session re-inject vs. fresh-process vs. one-shot, and how to fight
  context rot with memory layering. Grounded in measured rot findings. Reach for
  it when weighing "should I loop this" or architecting a long run.

## State layout (`.repete/`, per project — `/repete` adds it to your `.gitignore`)

```
.repete/
├── MISSION.md        # north star + the verifiable mission goal (the <repete-done> string)
├── loop.local.md     # frontmatter (phase/iteration/status/budgets/flags) + current loop payload
├── todo-next.md      # out-of-scope discoveries — seeds the next loop (only if todo_next_enabled)
├── transition.md     # the agent's proposed next payload, awaiting your approval
├── handoff.md        # in-flight snapshot written at a context checkpoint, read on rehydrate
├── parts.md          # gauntlet only: part · judgeable criterion · status
├── critique.md       # gauntlet only: last critic verdict (first line = WINNER)
└── lessons/          # one card per mistake/insight; retrieved into future loops (only if lessons_enabled)
```

## The two sentinels

The agent ends a unit of work by emitting one of:

- `<repete-checkpoint> …proposed next-loop payload… </repete-checkpoint>` — this loop's exit
  goal is met. Seeded from `todo-next.md` and lessons learned. You approve before it runs.
- `<repete-done> exact mission goal string </repete-done>` — the whole mission's goal is
  **verifiably** true. Only then does the run end.

The standing rules injected each iteration forbid emitting either sentinel just to escape —
the same honesty contract the Ralph loop relies on.

## Memory layers — what gets re-injected

Each iteration's re-inject is assembled from these layers, in this order. **Lessons are
opt-in** (`lessons_enabled: false` by default) — a default loop re-injects only the brief, the
constitution, and the frozen protocol, keeping each iteration quiet:

1. **Evolving brief** — the body of `loop.local.md`: this loop's exit goal + working
   brief. Changes at every checkpoint.
2. **Lessons catalog** *(only when `lessons_enabled: true`)* — *metadata only*: one line per lesson card
   (slug · tags · severity · hits), ranked by severity then hits, capped (default 8).
   The card **bodies** are never injected — the agent `Read`s only the relevant card
   on demand. This is deliberate: pasting card bodies every iteration is the exact
   context-rot source the catalog eliminates. (Card *count* stays decoupled from
   re-inject *size*.)
3. **User constitution** — `.repete/constitution.md`, your frozen project invariants
   (don't-touch dirs, "keep the public API stable", conventions). Injected with HTML
   comments stripped, only if it has real content — an unfilled comments-only starter
   is skipped, so it isn't pure bloat.
4. **Gauntlet working rules** *(only when `gauntlet: true`)* — `templates/gauntlet.md`:
   the builder/critic round discipline, plus a one-line pointer to the last critic
   verdict in `.repete/critique.md`. Falls back to an inline core if the template is
   unreadable (fail-functional, like the protocol).
5. **Engine protocol** — `templates/protocol.md`, the loop's standing rules (work from
   files, emit sentinels only when honest). Hook-owned, always injected **last** so the
   binding rules aren't buried under the payload. Falls back to an inline core if the
   template is unreadable (fail-functional — never lose the two sentinels).

When `lessons_enabled` is on and the agent hits a dead-end or a fix that didn't work, it writes a
**lesson card** to `.repete/lessons/` (see `templates/lesson-card.md`): situation → tried →
outcome → rule, tagged for retrieval. Cards are project-local in v1; recurrence-gated promotion to
a global `~/.claude/repete/` store is the v3 design. Likewise `todo_next_enabled` turns on the
"log out-of-scope finds to `todo-next.md`" rule. Both are off by default.

## Requirements

- `jq` and `perl` on `PATH` (`perl` ships with macOS; `jq` ships with recent macOS and
  most Linux distros — install it if missing). Without `jq` the hook fails open — it
  will not trap you in a loop it can't steer.
- The `remember` plugin is recommended (memory + `SessionStart` rehydrate) but not required.

## Install (local testing)

```bash
claude --plugin-dir .
```

Then `/repete <your mission>` in a project. `/repete-cancel` (or delete `.repete/`) to stop.

## Roadmap

- **v2** — mission as N named phases; `transition.md` advances a declared phase plan.
- **v3** — cross-project lessons in `~/.claude/repete/`, recurrence-gated promotion, a
  consolidation pass (dedup/generalize/age-out) to keep the library retrieval-sharp.
