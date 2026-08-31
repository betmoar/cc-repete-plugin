# AUDIT_STATE — cc-repete-plugin principal-architect audit

- **Mode:** AUTONOMOUS
- **Target:** /home/user/cc-repete-plugin @ a46abb2 (v0.2.1 → v0.2.2), branch `claude/principal-audit-autonomous-qwed7i`
- **Phase cursor:** DONE (P1–P4 complete, self-verified, 2026-08-31)
- **COMMIT gate:** commit + push to the designated branch + draft PR were pre-authorized by this session's standing instructions; nothing else outward was done (no installs, no deletes outside the tree, no other branches).

## Verdict

Unusually healthy codebase for its class: the fail-open philosophy is genuinely embodied, the decision order is documented at each site, and the test suite (237 baseline asserts + invariant/doc/golden locks) is the real safety net it claims to be. The defects found were at the edges the last hardening pass missed — two of them (F01, F02) violated the repo's OWN stated invariants (never fail closed; a hardened path covered only halfway), which is exactly where an audit should look next time too. The release machinery had drifted out of the maintainer map entirely.

## Findings → outcomes (full admissible ledger in AUDIT_LOG.md; IDs are THIS audit's, not the 2026-08-16 F1–F14)

| ID | Sev | What | Outcome |
| --- | --- | --- | --- |
| F01 | P2 | Unwritable `.repete/` → Stop blocked forever (fail-closed) | FIXED: blocking paths bail open with warning; locked by A-F01 tests (runuser/non-root ladder) |
| F02 | P2 | BOM'd state file silently drops payload body from re-inject | FIXED: body reads BOM-stripped CONTENT; locked by A-F02 test |
| F03 | P2 | Earlier-entry sentinel invisible AND resets stale counter | Reset half FIXED (neutral turn); visibility half deliberately deferred — reverses a test-locked v0.2.1 decision, needs real-transcript evidence (CLAUDE.md backlog #6) |
| F04 | P2 | Trailing space discards numeric value (cap 5 → backstop 25) | FIXED in fm() + statusline fmv; locked by A-F04 tests both suites |
| F05 | P2 | marketplace.json unvalidated by run-all/ci | FIXED: jq check added to both |
| F06 | P3 | release-gate.mjs untested | FIXED: tests/test-release-gate.mjs (9 cases) wired into run-all + ci |
| F07 | P3 | Release notes truncate at `[`-leading body line | FIXED: stop regex matches link-ref shape; test locks it |
| F08 | P3 | >18-digit lesson hits wraps negative in catalog | FIXED: num10 reuse; locked by A-F08 test |
| F09 | P3 | CLAUDE.md map missing release machinery | FIXED: couplings rows, step-5 release flow, landmines, backlog; doc-lock tests added |
| F10 | P3 | No golden-SHA regen tool | FIXED: tests/regen-golden.sh (proved golden unchanged by this audit) |

## Verification (evidence)

- Baseline BEFORE changes: hooks 237/0, statusline 24/0, ALL SUITES GREEN.
- After: hooks **256/0**, statusline **25/0**, release-gate **9/9 node:test**, ALL SUITES GREEN; `tests/regen-golden.sh` → "unchanged" (default re-inject byte-identical — golden SHA untouched).
- Every P2 fix re-verified against its original repro: F01 rc=0/no-block/warning as nobody+555; F02 body marker count 1; F03 stale_count stays 2; F04 cap file keeps 5.
- `node scripts/release-gate.mjs v0.2.2` → "release gate OK" with correct notes extraction (v0.2.2 is tag-ready).
- lint_findings.py on AUDIT_LOG.md → 10 findings, 0 problems.
- Coverage caps (logged, not silent): shellcheck not runnable in this container (CI enforces); no real Claude Code transcript available to validate #18 turn shapes beyond repo fixtures.

## Load-bearing map / implicit contracts

Carried in AUDIT_LOG.md (P1 entries) and, canonically, in CLAUDE.md — which this audit refreshed and which remains the single maintainer map. IC1–IC8 recorded in the P1 log entry; IC8 (CHANGELOG newest-first) is now test-enforced via the release-gate suite.

## Prioritized backlog (pickup-able cold; also reflected in CLAUDE.md "Residual risks")

1. **F03 residue — multi-entry-turn sentinel visibility** (CLAUDE.md backlog #6): decide join-the-turn vs last-entry with real transcript frequency data; both directions pinned in the `#18` + A-F03 test blocks.
2. **Per-Stop O(transcript) cost** (pre-existing backlog #5): unchanged by this audit — the F03 fix kept it one parse per Stop. The grow-the-window design constraints written there still hold.
3. **`/repete-continue` checkpoint promotion is prompt-code** (pre-existing backlog #1): a `hooks/promote.sh` would make it mechanical; the F01 fail-open pattern is the template for its failure direction.
4. **Transcript shape trust** (pre-existing backlog #2): watch Claude Code release notes; `$turn_start` in the hook is the sensitive spot.
5. Minor: `ci.yml` triggers on both push and pull_request (duplicate runs on PR branches) — cosmetic CI cost, not correctness.

## // DECISION log

- Audit state files at repo root, committed: they are audit deliverables on a dedicated branch.
- F03 fixed as NEUTRAL turn, not join-the-turn: joining reverses a test-locked design call and raises false-teardown risk (the expensive direction per the repo's own philosophy); needs transcript evidence first.
- New code comments cite "2026-08-31 audit Fxx" to avoid colliding with the 2026-08-16 audit's F1–F14 already cited in comments.
- Version bumped 0.2.1 → 0.2.2 with CHANGELOG + README per the repo's own release checklist, leaving the branch tag-ready; the maintainer decides when to tag.
