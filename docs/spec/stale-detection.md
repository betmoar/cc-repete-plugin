# Spec: stale detection — false done-claim feedback + `paused-stale` yield

> **Design record — may lag the code. `hooks/stop-hook.sh` is authoritative.** This file
> records what was approved and why, not what ships today. Refinements are appended as
> `> Refined in vX.Y.Z` notes pointing at the live logic; the original text is left standing.

Status: approved design (brainstorm `wf_6b69cf34-90a`, operator interview 2026-08-16).
Source: Gauntlet-loop engineering ideas (Prompt Index guide), filtered through this
repo's fail-open rule and couplings table.

## Locked decisions

1. **Done stays self-reported.** No verifier, no hook-executed commands from
   frontmatter. The human at checkpoint gates remains the only critic. (Kills the
   verifier-gate and metric-command directions; the fail-closed risk of a blocking
   verifier is disqualifying.)
2. **Stale-counter on the existing mismatch path now; a `<repete-spin>` sentinel is
   deferred.** One shared `paused-stale` status so a future sentinel becomes a second
   trigger, not a state-machine fork.
3. **Always-on, numeric switch.** `stale_limit` defaults to 3 when absent or
   unparseable; `0` disables. No boolean flag — the number is the switch, matching
   `max_iterations`.

## The defect this fixes

`hooks/stop-hook.sh` done-check block (at time of writing `:205-214`; later commits
on the same branch shifted anchors — see the current `(1) mission done?` block, the
early-exit `case "$(fm status)"`, and the `HAS_CHECKPOINT -eq 0` guard for live
positions): when the agent emits `<repete-done>X</repete-done>` and
`norm(X) != norm(mission_goal)`, the sentinel is silently ignored. The agent gets zero
feedback, often re-claims done with the same wrong string, and burns iterations until
the cap. This is the cheapest spinning signal in the system — it already reaches the
hook; it is just discarded.

## Hook change (`hooks/stop-hook.sh`)

**Frontmatter fields** (both written by the scaffold; hook reads with defaults):

- `stale_limit` — int, default 3 (absent/unparseable → 3; `0` → detector off).
  Failure direction: an always-on default means a runaway false-claim loop yields to
  the human at 3 — toward the human, never a trap.
- `stale_count` — int, hook-maintained, starts 0 (unparseable → 0).

**Placement** — inside the existing `[[ "$STATUS" != "summarizing" ]]` sentinel guard,
restructured within the done-check block (see the live `(1) mission done?` marker).
No decision-order change; the new
logic lives entirely inside the block whose precedence is already derived
(checkpoint-beats-done I2, autonomous checkpoint suppression, summarizing
suppression all apply unchanged):

```sh
if [[ $HAS_CHECKPOINT -eq 0 && -n "$MISSION_GOAL" && "$MISSION_GOAL" != "null" ]]; then
  DONE="$(... existing perl extract ...)"
  if [[ -n "$DONE" ]]; then
    if [[ "$(norm "$DONE")" == "$(norm "$MISSION_GOAL")" ]]; then
      ... existing teardown; exit 0 ...
    else
      # Mismatch: count, feed back, maybe yield. Failure direction: never
      # tears down, never blocks past stale_limit — worst case it yields to
      # the human, the safe direction.
      STALE=$((STALE + 1)); set_fm stale_count "$STALE"
      if [[ "$STALE_LIMIT" -gt 0 && "$STALE" -ge "$STALE_LIMIT" ]]; then
        set_fm status paused-stale
        emit "🧭 repete: $STALE consecutive done-claims did not match the mission goal ..." ; exit 0
      fi
      STALE_NOTE="--- repete: your <repete-done> claim ('...') does NOT match the stored mission goal ('...') — claim ${STALE}/${STALE_LIMIT}. Re-read .repete/MISSION.md: either the work is not actually done, or you are quoting the goal string wrong. Do not re-emit the same claim unchanged."
    fi
  else
    # No done-sentinel this turn: the agent did work, not a false claim.
    # Reset the counter (write only if non-zero, to avoid a pointless write
    # per Stop). Deliberate: an agent interleaving real work with claims
    # resets — protects stage-wise approaches from false positives.
    [[ "$STALE" -gt 0 ]] && { set_fm stale_count 0; STALE=0; }
  fi
fi
```

> **Refined in v0.2.2** (2026-08-31 audit F03): "no done-sentinel this turn" means no
> `<repete-done>` anywhere in the turn's text. A turn whose sentinel sits in an
> EARLIER text entry (claim, then a tool call or wrap-up text) is NEUTRAL — not
> honored, not counted (the last-text-entry-wins rule above stands), and no longer a
> reset either: pre-fix, an agent that habitually appended text after its claims
> could never trip `paused-stale`. Only a genuinely sentinel-free turn resets. Live
> logic: the `TURN_HAS_DONE` probe in `hooks/stop-hook.sh`'s done-check else-branch.

> **Refined in v0.2.3** (issue #21): every bare `set_fm` in the snippet above is now
> `set_fm_or_warn`. The snippet's writes discarded their return value, so on an
> unwritable `.repete/` the hook emitted the `paused-stale` yield (or the rejection
> note) while state stayed `running` and `stale_count` stayed 0 — meaning `stale_limit`
> could never be reached and this whole mechanism was silently inert. The guard emits a
> could-not-save warning instead of the claimed outcome, sets no `decision`, and exits 0.
> The failure direction described above is unchanged: never tears down, never blocks.
> Live logic: `set_fm_or_warn` in `hooks/stop-hook.sh`.

`STALE_NOTE` (when set) is prepended to the re-inject assembly after the body and
before the lesson catalog — it is per-turn feedback, not durable state, and carries
no lesson-card bodies (metadata-only rule untouched).

**Autonomous mode:** the stale yield is a budget-class stop, like the iteration cap —
it does not violate "only done/budgets stop an autonomous loop". An autonomous loop
that repeatedly false-claims done is exactly the failure this catches; yielding to
the human at the threshold is the intended backstop.

**Early-exit case** (the `case "$(fm status)"` block near the top): add `paused-stale`
to the terminal/paused status list so
a subsequent Stop in that state exits 0 without re-injecting.

## Status machine

`running → paused-stale` (via threshold). Resume path: `/repete-continue` resets
`stale_count` to 0, blanks `session_id`, returns to `running`. The human may also
raise `stale_limit`, fix `mission_goal`, or `/repete-cancel`.

## Prompt-code changes (coupling tax — all four sites for a new status)

> Refined in v0.2.3: the two bundled skills were consolidated into a single
> `skills/repete-loops/`. The row below naming `skills/running-repete-loops/SKILL.md` now
> maps to that skill's §4 "Reading the yields" (`paused-stale`) and §6 "Debugging" (the
> done-claim-ignored symptom). The coupling itself is unchanged — a status still costs a
> skill edit; only the path moved.

| Site | Change |
| --- | --- |
| `templates/loop.local.md` | add `stale_count: 0` and `stale_limit: 3` to frontmatter |
| `commands/repete.md` | scaffold instructions gain both keys; budgets prose mentions stale_limit |
| `commands/repete-status.md` | render `stale_count/stale_limit`; "what to do next" map gains `paused-stale` |
| `commands/repete-continue.md` | `paused-stale` branch: reset count, blank session, resume; mention editing goal/limit |
| `commands/repete-cancel.md` | none (already terminal-path agnostic) |
| `hooks/stop-hook.sh` | as above |
| `tests/test-hooks.sh` | blocks below; `scaffold()` writes both keys |
| README | budgets table + status list + one paragraph on mismatch feedback |
| `skills/running-repete-loops/SKILL.md` | done-semantics section: describe rejection feedback + stale yield |
| CLAUDE.md | decision-order line (mismatch handling inside done block), status machine, couplings row |
| `templates/protocol.md` + `PROTO_FALLBACK` | **unchanged** — the injected note is self-explanatory; avoid the highest-blast-radius coupling |

## Tests (write first, all `ck` blocks in `tests/test-hooks.sh`)

1. Mismatch bumps + annotates: emit mismatched done → no teardown, `stale_count` 1,
   re-inject contains "does NOT match".
2. Threshold yields: 3rd consecutive mismatched done → status `paused-stale`, exit 0.
3. Reset on work turn: mismatch, then plain work turn → `stale_count` 0.
4. `stale_limit: 0` disables: 5 mismatches → still `running`, counter inert.
5. Absent field defaults on: scaffold without `stale_limit` → mismatch counts to 3.
6. `paused-stale` early-exits: setstate → run → exit 0, no re-inject.
7. Checkpoint beats mismatch (I2): mismatched done + checkpoint in one message →
   `paused-checkpoint`, no count bump.
8. Summarizing suppression: status `summarizing` + mismatched done → no count; the
   budget two-step owns the Stop.
9. Invariant block: **a mismatched done never sets `status: done`** — teardown
   requires an exact goal match, with or without stale fields present.

Audit existing tests first for consecutive-mismatched-done sequences that would now
hit the threshold (baseline before change; report delta, never edit an invariant to
pass).

## Version

`0.1.4 → 0.2.0` (new state-machine status = minor): `.claude-plugin/plugin.json` +
README version line. Ship on `feat/stale-detection`.

## Out of scope (deferred, with rationale)

- **`<repete-spin>` sentinel** — revisit if real loops show sustained stalls that
  never claim done. Design constraint to preserve: it must trigger the SAME
  `paused-stale` status (second trigger, not a fork).
- **Verifier / metric command in frontmatter** — rejected: hook-executed commands
  from a gitignored agent-written file are a new trust surface, and a blocking
  verifier is fail-closed on the forbidden axis. Advisory-verifier variant may be
  re-opened later if "done is self-reported" ever proves too weak in practice.
- **Builder/critic separation, decomposition + integration pass** — not implementable
  in a single-pass shell hook; the v2 phased-missions roadmap is where decomposition
  lives. The /clear+rehydrate flow and the human at paused-* gates are the honest
  substitutes.

---

## Appendix (2026-09-03): issue #24 settled by measurement — last-entry-wins STAYS

> **Refined-in-place decision record, not a rewrite of the sections above.** The
> multi-entry-turn question flagged in the 2026-08-31 audit (F03 residue) is closed.

Measurement over 756 local `.claude/projects` sessions (55,676 main-thread entries,
1,482 text-bearing turns; boundary predicate identical to the hook's):

- Turns containing a done-ish claim: **209**. Hook sees the claim in the last
  text-bearing entry: **178 (85%)**. Claim sits in an earlier text entry: **31 (15%)**.
- Multi-entry turns where an EARLIER entry claims and the last does not: **33**.
  Later text **retracts or qualifies** the claim: **23 (70%)**. Later text is neutral
  wrap-up: **10 (30%)**.

**Decision:** joining all of a turn's text entries for sentinel detection would honor
the 30% at the cost of tearing down on the 70% — a claim the agent verbally walked
back would END the loop, the exact expensive direction v0.2.1 locked against. The
15% invisible-claim loss is the accepted cost: it burns iterations to a budget (the
cheap direction), a repeated mismatched claim still trips `paused-stale`, and every
yield reaches the human. Both directions are now mechanically locked in the `#24`
decision-lock block in `tests/test-hooks.sh`, adjacent to the `#18` block; flipping
the trade requires flipping both assertions together.

Also measured the same day (Stop hook input, live session, `claude 2.1.259`): the
input carries `last_assistant_message` — the final assistant text of the turn,
delivered by the harness — and **no token or context-usage field**. A future switch
from transcript parsing to `last_assistant_message` must preserve the `#18`/`#24`
invariants (turn-bounded scan, last-text-entry-wins, malformed-block tolerance).

## Appendix (2026-09-03): issue #15 — lines stay the rot proxy

> Decision record for the "line vs byte vs token" question.

Measured: (a) Stop hook input has **no token/context signal** (field list above);
(b) across 34 real transcripts, bytes-per-line spans **1.1–15.7 KB** — a
file-reading loop's tool outputs are fat lines and a chatty loop's are thin, so a
byte budget tracks the same noise, one power-of-ten larger. A byte budget is NOT
more trustworthy; it just moves the arbitrary unit. Lines stay. Reopen only when
the harness ships a tokens-ish field in Stop input (watch the field list pinned in
the `#24` test block).
