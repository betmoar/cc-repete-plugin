# Spec: gauntlet mode — builder/critic rounds inside the repete loop

> **Design record — may lag the code. `hooks/stop-hook.sh` is authoritative.** This file
> records what was approved and why, not what ships today. Refinements are appended as
> `> Refined in vX.Y.Z` notes pointing at the live logic; the original text is left standing.

Status: approved (user "go" 2026-08-16, after stale-detection v0.2.0 on feat/stale-detection).
Source: the Gauntlet pattern (Prompt Index guide), full seven steps — including the ones the
stale-detection brainstorm converged away from. Supersedes that convergence for THIS feature
only; the locked decisions there (done = self-report, fail-open, no hook-executed commands)
remain binding.

## Core insight

The hook does not run the Gauntlet — the loop agent does. The hook stays what it is
(loop engine, budgets, done-detection) and gains only a default-off flag that injects
Gauntlet working rules. Builders and critics are subagents the lead agent dispatches via
its normal Agent tool; the sidechain guard (subagent sentinels already ignored,
tests/test-hooks.sh "Sidechain sentinel is ignored") is what makes stray subagent
sentinels harmless. Fail-open untouched: `gauntlet: false` (default) = byte-identical
behavior.

## The seven steps, mapped

| Gauntlet step | Mechanism |
| --- | --- |
| 1. Ambitious goal + concrete example of "great" | `reference:` (path or URL) + `bar:` (one line, what "good enough" means) in loop.local.md frontmatter — the only homes for both; MISSION.md carries the mission goal as before (no Reference section shipped; the working rules point the agent at the frontmatter keys) |
| 2. Split into smallest independently judgeable parts | lead agent maintains `.repete/parts.md`: one line per part — part, judgeable criterion, status (todo/doing/done) |
| 3. Each important part → a builder | builder = one subagent per part (or batch), dispatched by the lead; main thread = lead + integrator only |
| 4. Output → separate critic with fresh context | critic = subagent receiving a minimal packet: the reference, the artifact locations, the parts list — never the builders' reasoning or conversation |
| 5. Critic compares directly against reference, blind A/B | rounds = commits; the critic sees round N and round N−1 unlabeled (`git show <sha>` each) plus the reference, picks a winner and names the largest meaningful gap |
| 6. Loser → largest gap → another round | verdict written to `.repete/critique.md`; the gap becomes the top priority in the next re-inject |
| 7. Repeat until bar / boundary / stop | existing budgets: `max_iterations` = rounds, `context_budget_lines`, `stale_limit`. Done stays goal-match; protocol adds: claim done only after a final integration-critic pass |

## Frontmatter (all default-off / inert)

- `gauntlet: false` — the switch. Absent/unparseable → false (fail toward today's behavior).
- `reference: ""` — path or URL to the concrete example. Only meaningful with gauntlet on.
- `bar: ""` — one line: what the critic treats as "reached the bar".

Adding keys = the standard five-site frontmatter coupling (template, hook fm reads,
/repete scaffold, /repete-status render, tests scaffold()).

## Hook change (small, fail-open stated)

1. Read the three keys next to the other fm reads (same numeric/string default pattern;
   gauntlet/reference/bar absent → false/""/"").
2. When `gauntlet: true`, inject the Gauntlet rules into the re-inject. Mechanism:
   read `templates/gauntlet.md`; if unreadable, inline `GAUNTLET_FALLBACK` (same
   fail-functional pattern as PROTO_FALLBACK — the loop must never lose its rules).
   Placement: after the constitution, before the protocol (working rules, not frozen
   engine core). Include a pointer to `.repete/critique.md` when it exists ("last critic
   verdict: first line").
3. Failure direction: every path degrades to "no gauntlet rules injected" — never to a
   blocked Stop. Missing template → fallback; missing critique.md → no pointer line;
   bad flag → off.

## templates/gauntlet.md (the working rules, injected each iteration)

Imperative, numbered, unambiguous — precision of wording IS the implementation:

1. Maintain `.repete/parts.md` (part · judgeable criterion · status). Split finer when a
   part cannot be judged on its own; merge when a part is too small to be worth judging.
2. Assign each open part to a builder subagent. One part per builder; give it the part,
   the criterion, the file paths, and nothing else.
3. Integrate builder output yourself. Do not let two builders touch the same file.
4. Critique every round: dispatch ONE critic subagent with a fresh context. Give it:
   the reference, `git show` of this round and the previous round (unlabeled), the parts
   list, the bar. Do NOT give it your reasoning or the builders'.
5. The critic picks a winner between the two rounds and names the single largest
   meaningful gap versus the reference. Write its verdict to `.repete/critique.md`
   (overwrite), first line `WINNER: <round>` or `WINNER: none`.
6. Work the gap: the named gap is the top priority of this iteration. If the critic
   says the bar is reached for every part, run one final integration critic over the
   WHOLE artifact before claiming done.
7. Only claim `<repete-done>` after that final integration pass agrees the mission
   goal is verifiably true. Never emit it to escape a losing round.

Round discipline: one round = one iteration = ideally one commit. A round that loses
to the previous round is not wasted — the gap it exposes is the next round's target.

## Prompt-code changes

> Refined in v0.2.3: the two bundled skills were consolidated into a single
> `skills/repete-loops/`. The two rows below (the running skill's "Gauntlet runs" section
> and the designing skill's one-paragraph pointer) collapse into one live site:
> `skills/repete-loops/references/gauntlet.md`, summarized by §5 of that skill's SKILL.md.
> The round discipline and critic-packet hygiene described below are unchanged.

| Site | Change |
| --- | --- |
| `templates/loop.local.md` | + `gauntlet: false`, `reference: ""`, `bar: ""` |
| `commands/repete.md` | Optional-features section: gauntlet entry (when to use: ambitious quality bar + a real reference exists; asks reference + bar; creates `.repete/parts.md` + `.repete/critique.md` seeds); budgets prose unchanged (rounds = iterations) |
| `commands/repete-status.md` | When gauntlet on: render reference/bar, parts (done/total), last critique first line |
| `commands/repete-continue.md` | Unchanged — resume paths are gauntlet-agnostic (parts.md/critique.md are durable state on disk) |
| `skills/running-repete-loops/SKILL.md` | New "Gauntlet runs" section: when to choose it, the round discipline, critic packet hygiene (fresh context = no builder reasoning), blind A/B via git show |
| `skills/designing-autonomous-loops/SKILL.md` | One paragraph: gauntlet = builder/critic decomposition for quality bars; links to running skill |
| README | Feature list + a Gauntlet section (the seven steps as implemented) + statusline note (no change) |
| CLAUDE.md | Couplings row (gauntlet keys + template), landmine (GAUNTLET_FALLBACK mirrors PROTO_FALLBACK), decision-order note (gauntlet injection between constitution and protocol) |

`templates/protocol.md` + `PROTO_FALLBACK`: UNCHANGED. Gauntlet rules are a separate
template — the frozen engine core keeps its blast radius.

## Tests (red-first, ck blocks in tests/test-hooks.sh)

1. `gauntlet: true` → re-inject contains the gauntlet rules (grep a stable phrase from
   templates/gauntlet.md, e.g. "parts.md").
2. Default off → no gauntlet rules in re-inject (grep absent).
3. Garbage flag → off.
4. Template unreadable (CLAUDE_PLUGIN_ROOT at empty dir) → GAUNTLET_FALLBACK still
   carries the rules incl. the final-integration-pass line.
5. `.repete/critique.md` exists → re-inject carries its first line (WINNER: ...).
6. No critique.md → no pointer line, everything else normal.
7. Coupling lock: every `## `-heading-level rule keyword... (skip — no heading coupling
   here; instead) template-not-empty lock: grep that templates/gauntlet.md contains the
   phrase the hook greps for (mirror of the PROTO sentinel test).
8. Fail-open: gauntlet on + missing MISSION/etc. — loop still blocks+re-injects as today
   (no new exit paths).
9. scaffold() gains the three keys; existing suites unaffected (default off).

## Version

Stays 0.2.0 per maintainer decision (2026-08-16): the branch is unreleased; version
bump happens at release time, not per feature branch. README's v0.2.0 line already
names gauntlet rounds. Ship on `feat/gauntlet-mode` (stacked on feat/stale-detection;
independent files, no conflict expected except tests/test-hooks.sh append points).

## Out of scope

- Critic invoked by the hook (rejected: single-pass shell, no model spawning; also
  violates the no-hook-executed-commands decision).
- Critic verdict gating done (rejected: done stays self-report; the critic shapes the
  WORK, the human at gates stays the final check).
- Per-part sub-loops with own budgets (v2 phased missions territory).
- Reference hashing / automated metric capture (the earlier metric-command direction —
  still rejected on trust-surface grounds).
