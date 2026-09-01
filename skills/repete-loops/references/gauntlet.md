# Gauntlet runs — builder/critic rounds against a reference

Read this before enabling `gauntlet: true`, or when a gauntlet run isn't converging.

A gauntlet turns iterations into reference-driven improvement rounds. It's the mode for
raising an artifact to an ambitious quality bar — the case where "is this good?" needs a
judgment the builder cannot be trusted to make about its own work.

This is an orthogonal axis to memory layering: **layering fights context rot, the critic
fights builder bias.** They compose; neither substitutes for the other.

## Prerequisites — both required

The hook enforces this. With either key empty, the working rules are withheld and the loop
runs plain, because a gauntlet with nothing to A/B against is iteration-burning theater.

- **`reference:`** — a concrete example of "great" the agent can actually read: a path, repo,
  or URL. No reference → nothing to compare against → the rounds are ritual.
- **`bar:`** — one line stating what "reached the bar" means. This is the *critic's* stop
  criterion, and it is not the mission goal.

## Who does what

The hook injects the gauntlet working rules each iteration from `templates/gauntlet.md` and
carries the critic's verdict line forward. **The agent — not the hook — runs the pattern**,
using its own subagents. The loop engine is untouched: budgets, sentinels, and done-detection
behave exactly as in a plain loop. A critic never gates the done sentinel, and stray sentinels
emitted by builder or critic subagents are ignored by the sidechain guard.

## The round discipline

One round ≈ one iteration ≈ one commit.

1. **The lead maintains `.repete/parts.md`** — one line per part: part · judgeable criterion ·
   status. Split finely enough that each part can be judged on its own; merge parts too small
   to be worth judging.
2. **One builder subagent per open part.** It gets the part, the criterion, and the file paths
   — nothing else. Never two builders on one file. The lead integrates on the main thread and
   is not itself a builder.
3. **One critic per round, with a fresh context.** It receives the reference, `git show` of
   this round and the previous round **unlabeled** (blind A/B — it must not know which is
   newer), the parts list, and the bar. It never sees the lead's or the builders' reasoning.
4. **The critic picks a winner and names the single largest meaningful gap** versus the
   reference. Its verdict goes to `.repete/critique.md` (overwritten each round), first line
   exactly `WINNER: <round>` or `WINNER: none`. The hook injects that first line into the next
   re-inject, so the lead opens the round already knowing the verdict.
5. **The named gap is the next round's top priority.** Rounds repeat until every part meets
   the bar, a budget fires, or the run is stopped.
6. **When every part is at the bar, run ONE final integration critic** over the whole artifact
   together. Only after it agrees is the mission goal claimable — and `<repete-done>` still
   requires the exact goal-string match. The critic shapes the work; the sentinel remains the
   exit.

Never emit the done sentinel to escape a losing round. A lost round isn't wasted — its gap is
the next round's target.

## Critic-packet hygiene — where these runs succeed or rot

**The critic that receives the builder's justifications stops judging the artifact and starts
grading homework.** Everything about the packet follows from that: fresh context, unlabeled
diffs, no reasoning from the lead or builders, the reference and the bar supplied directly.

It is the same class of failure as a vague mission goal — the harness looks correct while the
signal it produces is worthless. Guard the packet, not the prompt.

## Composing with the rest of the engine

- **`max_iterations`** doubles as the round cap: rounds are iterations.
- **`context_budget_lines`** still fires; a gauntlet run generates plenty of subagent traffic
  on the main thread, so expect the context yield.
- **`stale_limit`** still fires, and is a useful signal here: repeated mis-claims during a
  gauntlet usually mean the bar and the mission goal have drifted apart.
- **`autonomous`** composes cleanly — rounds then run unattended between budgets.

Seeds `/repete` creates when the flag is on: `.repete/parts.md` (header line only) and
`.repete/critique.md` (empty).
