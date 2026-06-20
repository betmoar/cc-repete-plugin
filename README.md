# repete

Self-evolving autonomous loops for Claude Code.

`repete` formalizes a Ralph-loop workflow into one plugin: an autonomous iteration loop
that **evolves its own payload** at each human-gated checkpoint, **harvests out-of-scope
discoveries** as the seed for the next loop, **learns from its mistakes** into a project
lesson library, and **fights context rot** by turning a transcript-size budget into a
`/clear` + rehydrate checkpoint. It reuses the [`remember`](https://github.com/anthropics/claude-code)
plugin for tiered memory rather than reinventing it.

This is **v0.1.1** — a single evolving loop with project-local lessons. Multi-phase mission
chaining (v2) and cross-project global learning (v3) build on the same state model.

## How it works

A `Stop` hook is the loop engine. Every time the agent tries to stop, it makes a three-way
decision:

| Last output contains                                        | Hook does                                                                                           |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `<repete-done>GOAL</repete-done>` matching the mission goal | tears the loop down — **mission complete**                                                          |
| `<repete-checkpoint>…payload…</repete-checkpoint>`          | writes the proposed payload to `.repete/transition.md` and **yields to you** for approval           |
| neither                                                     | **blocks the stop and re-injects** the current loop payload + standing rules (autonomous iteration) |

Two safety yields also stop the autonomous run and hand control back:

- **`max_iterations`** reached → paused; `/repete-continue` to raise the cap.
- **`context_budget_lines`** exceeded → paused; `/clear` then `/repete-continue` rehydrates
  a fresh context from `.repete/` state. This is the anti-context-rot mechanism. The budget
  counts raw transcript JSONL lines (a loose proxy for context size, not tokens), default 2500.

So: iterations run unattended; **you are only in the loop at transitions** — exactly where
drift and bad decisions compound.

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

## State layout (`.repete/`, per project, git-ignored)

```
.repete/
├── MISSION.md        # north star + the verifiable mission goal (the <repete-done> string)
├── loop.local.md     # frontmatter (phase/iteration/status/budgets) + current loop payload
├── todo-next.md      # out-of-scope discoveries — seeds the next loop
├── transition.md     # the agent's proposed next payload, awaiting your approval
└── lessons/          # one card per mistake/insight; retrieved into future loops
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

Each iteration's re-inject is assembled from four layers, in this order:

1. **Evolving brief** — the body of `loop.local.md`: this loop's exit goal + working
   brief. Changes at every checkpoint.
2. **Lessons catalog** — *metadata only*: one line per lesson card
   (slug · tags · severity · hits), ranked by severity then hits, capped (default 8).
   The card **bodies** are never injected — the agent `Read`s only the relevant card
   on demand. This is deliberate: pasting card bodies every iteration is the exact
   context-rot source the catalog eliminates. (Card *count* stays decoupled from
   re-inject *size*.)
3. **User constitution** — `.repete/constitution.md`, your frozen project invariants
   (don't-touch dirs, "keep the public API stable", conventions). Injected verbatim
   only if it has real content — an unfilled comments-only starter is skipped, so it
   isn't pure bloat.
4. **Engine protocol** — `templates/protocol.md`, the loop's standing rules (work from
   files, emit sentinels only when honest). Hook-owned, always injected **last** so the
   binding rules aren't buried under the payload. Falls back to an inline core if the
   template is unreadable (fail-functional — never lose the two sentinels).

When the agent hits a dead-end or a fix that didn't work, it writes a **lesson card** to
`.repete/lessons/` (see `templates/lesson-card.md`): situation → tried → outcome → rule,
tagged for retrieval. Cards are project-local in v1; recurrence-gated promotion to a
global `~/.claude/repete/` store is the v3 design.

## Requirements

- `jq` and `perl` on `PATH` (both ship with macOS). Without `jq` the hook fails open — it
  will not trap you in a loop it can't steer.
- The `remember` plugin is recommended (memory + `SessionStart` rehydrate) but not required.

## Install (local testing)

```bash
claude --plugin-dir /Volumes/Data/Workspace/dev/claude-plugins/cc-repete-plugin
```

Then `/repete <your mission>` in a project. `/repete-cancel` (or delete `.repete/`) to stop.

## Roadmap

- **v2** — mission as N named phases; `transition.md` advances a declared phase plan.
- **v3** — cross-project lessons in `~/.claude/repete/`, recurrence-gated promotion, a
  consolidation pass (dedup/generalize/age-out) to keep the library retrieval-sharp.
