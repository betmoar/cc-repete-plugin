# Spec: v2 phased missions — mission as N named phases

> **Design record — proposed, not yet approved.** Nothing here ships; it is the
> evaluable design for issue #13. `hooks/stop-hook.sh` stays authoritative for
> whatever exists today. Locking direction BEFORE approval: fail-open untouched,
> no hook-executed commands, done stays self-reported, metadata-only catalog.

Status: draft (issue #13, README v2 roadmap). Written 2026-09-03 from the in-place
design hooks (phase counter, promote.sh seam, gauntlet compatibility) — no
implementation exists.

## Problem

A long mission today is a sequence of hand-promoted loops: at each checkpoint the
human reads `transition.md`, edits the payload, and `/repete-continue` re-scaffolds.
That works but the PLAN lives nowhere machine-readable — the hook cannot render
"phase 2 of 5", cannot validate that a proposed next phase follows the declared
order, and the human re-derives the shape of the mission at every checkpoint.

## Design

### 1. `phases:` in loop.local.md frontmatter — the declared plan

```yaml
phases:
  - name: parser green
    exit: "all parser tests pass"
  - name: serializer round-trips
    exit: "round-trip fixtures byte-identical"
  - name: docs + release
    exit: "CHANGELOG entry merged"
```

- Key absent (default) → byte-identical behavior today: `phase` counts up
  unbounded, nothing validates. Fail-open direction: unparseable `phases:` →
  ignore the plan, behave as v1.
- `phase` (existing key) becomes 1-indexed INTO `phases` when present. The hook
  reads `phases[phase-1].name` for the re-inject; out-of-range `phase` → clamp to
  the last entry + warn once (never trap).

### 2. What the hook gains (small, additive)

- Re-inject gains one line above the protocol: `Phase 2/5: serializer round-trips
  — exit: round-trip fixtures byte-identical`. The phase exit joins the mission
  goal as a second verifiable string the agent can `<repete-done>` against (either
  match tears down; the strict exact-string rule applies to both).
- `/repete-status` and the statusline render `2/5` from `phase` + `phases|length`.
- **No new stop condition.** Budgets, checkpoint, stale, context — unchanged. A
  phase boundary is still a checkpoint the human promotes; the hook never advances
  `phase` itself (that is promote.sh, below).

### 3. promote.sh gains `--phase` (the only writer)

`hooks/promote.sh` already writes six keys atomically including `phase: +1`. With
`phases:` present it additionally validates the PROPOSED next payload's first
phase-exit against `phases[N]` — reject loud (its existing failure mode) when the
proposal skips or reorders the declared plan. `/repete-continue` step 4 passes the
proposal; a rejection surfaces to the human, who can edit or override the plan
file. The plan is editable between phases — it is a living document, not a
contract signed at loop start; validation catches typos and reordering accidents,
not deliberate re-plans (an explicit `--replan` flag re-baselines).

### 4. Gauntlet compatibility

A phase may declare itself one gauntlet round-set (`gauntlet: true` already
per-loop; a per-phase override rides the same `phases:` entry as optional keys).
The injection rule (both `reference:` and `bar:` required) applies per phase read.

## Acceptance (from issue #13, made testable)

- [ ] `templates/loop.local.md` gains a commented-out `phases:` example; scaffold
  prose in `commands/repete.md` explains it (default absent = today's behavior)
- [ ] Hook reads `phases[phase-1]`; absent/garbage → v1 behavior (ck: no crash,
  no new block, phase line absent from reason)
- [ ] Re-inject carries the `Phase N/M: name — exit:` line only when `phases:`
  parses (ck both directions)
- [ ] Statusline + `/repete-status` render `N/M` (ck)
- [ ] promote.sh `--phase` validates proposal order; rejects with a named error;
  `--replan` re-baselines (ck via test-promote.sh)
- [ ] Golden SHA regenerated deliberately (re-inject line added)

## Out of scope

- Auto-advancing phases without a human checkpoint — rejected: the checkpoint IS
  the drift gate; automating it removes the only human judgment point.
- Cross-loop phase memory (a mission spanning multiple loop files) — v3 territory
  with the global lesson store (#14).
