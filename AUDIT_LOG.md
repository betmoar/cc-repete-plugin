# AUDIT_LOG — append-only

- 2026-08-31 P1: mode=AUTONOMOUS target=/home/user/cc-repete-plugin@a46abb2 (v0.2.1). No prior AUDIT_STATE.md — fresh audit. Prior 2026-08-16 "max audit" referenced by CLAUDE.md predates v0.2.1.
- 2026-08-31 P1: baseline captured BEFORE any change: run-all.sh → ALL SUITES GREEN (hooks 237/0, statusline 24/0). jq 1.7, node 22.22.2, perl ok, shellcheck ABSENT (cannot install pre-gate; CI covers it) — coverage cap.
- 2026-08-31 P1: read 100% of non-git files (3,949 LOC): hook, both test suites, statusline, 4 commands, 7 templates, 2 skills, README, CHANGELOG, CLAUDE.md, 2 specs, 4 manifests, ci.yml, release.yml, release-gate.mjs, golden sha, .gitignore.
- 2026-08-31 P1: EXIT CRITERIA met — load-bearing map (10 entries, ranked), implicit contracts (IC1–IC8), intent/behavior delta written to AUDIT_STATE.md. Cursor → P2.

- 2026-08-31 P2: domain sweeps complete (correctness, security, robustness, quality, gaps, footguns). Probes a–g run; 6 reproduced defects, 4 doc/tooling gaps. NOTE: finding IDs below are namespaced to THIS audit (2026-08-31); `audit F1…F14` in code comments refer to the prior 2026-08-16 audit.
- 2026-08-31 P2: clean bills (evidence: full read + probes): security — no injection surface (jq --arg everywhere, no eval outside test harness ck(), hooks.json quoted, no network, no secrets); the v0.2.1 decision-order + fail-open embodiments verified against the code as documented; test suite (237+24 asserts, invariant locks, doc-locks, golden SHA) is exemplary and was not padded with manufactured findings.
- 2026-08-31 P2: coverage caps — shellcheck unavailable in this container (CI enforces it; not run locally). No real Claude Code transcript available to re-verify the #18 turn-boundary shapes beyond the repo's own fixtures.

### [F01] State-write failure turns the loop engine fail-closed: Stop blocked forever
- **Location:** hooks/stop-hook.sh:464-465 (pass-1: `: > handoff.md`; `set_fm status summarizing`) and hooks/stop-hook.sh:508 (`set_fm iteration "$NEXT"`)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — reproduced as user `nobody` with `chmod 555 .repete/` and context_budget_lines exceeded: three consecutive Stops each returned `decision=block`, status stayed `running`, iteration stayed 1 (probe t4, 2026-08-31).
- **Failure trigger:** `.repete/` becomes unwritable mid-run (disk full / ENOSPC on a long autonomous run, perms change). Pass-1 of the context-budget two-step re-fires on every Stop because `status: summarizing` never persists and pass-1 never bumps iteration — so neither budget can ever fire. Same class: any `set_fm iteration` failure freezes the counter, so `max_iterations` becomes unreachable while re-injects continue.
- **Blast radius:** every Stop attempt is blocked with a re-inject; the agent is told to write a file it cannot write and to emit no sentinel. Silent (no error surfaced). This is the one direction the engine documents as forbidden (fail-closed).
- **Evidence:** probe output `Stop#1..3 decision=block status=running iter=1` with `.repete` mode 555, run as nobody.
- **Fix:** make the two blocking paths bail open when the state write fails: `set_fm status summarizing || { emit …; exit 0; }` and `set_fm iteration "$NEXT" || { emit …; exit 0; }` (set_fm already propagates failure via `awk > tmp && mv`). Failure direction: loop goes inert with a visible warning — same philosophy as the no-jq branch.
- **Guardrail:** test that runs the hook against a read-only `.repete/` (chmod 555; via runuser -u nobody when EUID=0, plain otherwise; SKIP only when neither works) asserting the Stop is NOT blocked.

### [F02] BOM'd state file silently drops the entire payload body from every re-inject
- **Location:** hooks/stop-hook.sh:512 (`PAYLOAD_BODY="$(awk … "$STATE_FILE")"` — reads the file RAW; the BOM strip at :70-75 feeds only the frontmatter reader)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — reproduced: BOM'd state file with body marker `UNIQUE-BODY-MARKER` → `decision=block` but marker absent from `.reason` (probe t6, 2026-08-31).
- **Failure trigger:** state file gains a UTF-8 BOM (Windows editor — the exact trigger the prior audit's F7 hardened frontmatter against). The BOM glues to the opening `---`, awk's fence counter never reaches 2, body extraction yields "".
- **Blast radius:** the loop keeps iterating but re-injects only catalog/constitution/protocol — the working brief (exit goal) is gone. Silent; the agent drifts with no brief while the loop looks healthy.
- **Evidence:** probe t6 output `BODY MISSING FROM RE-INJECT` (grep count 0) with decision=block.
- **Fix:** extract PAYLOAD_BODY from the same BOM-stripped in-memory content the frontmatter reader uses (body must keep CRs and bytes otherwise — only the leading BOM strip is shared). C1 guarantees set_fm never edits the body between read and use, so the in-memory copy is safe.
- **Guardrail:** extend the existing BOM test to assert the body text rides the re-inject, not just `decision=block`.

### [F03] A sentinel in an earlier same-turn text entry is invisible — and a mismatched one RESETS the stale counter
- **Location:** hooks/stop-hook.sh:302-320 (last text-bearing entry selection) + :377-386 (plain-work-turn reset)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — reproduced both shapes: (1) matching done-claim → tool_use → tool_result → trailing text ⇒ no teardown, stale_count reset to 0; (2) mismatched claim + trailing text with stale_count=2 ⇒ reset to 0 (probes t2/t3, 2026-08-31).
- **Failure trigger:** the agent emits the sentinel and then any further text entry in the same turn (e.g. claim → tool call → "all wrapped up" summary — a common model habit). Only the LAST text-bearing entry is scanned, so the claim is neither honored nor counted; the no-sentinel branch then treats the turn as plain work and resets stale_count.
- **Blast radius:** correct claims burn iterations to the budget (bounded, documented-adjacent); the reset half is strictly a defect — an agent that habitually appends text after claims can NEVER trip paused-stale, defeating the spin detector the feature exists for. Silent.
- **Evidence:** probe t2: `status: running / active: true / stale_count: 0` after a MATCHING claim + trailing text; probe t3: `stale_count: 2` → `stale_count: 0` after a mismatched claim + trailing text (2026-08-31).
- **Fix:** minimal, semantics-preserving: when LAST_OUTPUT carries no sentinel but the turn's OTHER text entries do, make the turn NEUTRAL — skip the stale_count reset (no count, no teardown, no reset). The locked v0.2.1 decision ("a later text entry wins — no teardown") stays intact; only the unintended counter reset is removed. The larger question (should the whole turn's text be joined?) reverses a test-locked design decision and goes to the backlog, not this fix.
- **Guardrail:** tests: mismatched-claim+trailing-text preserves a prior stale_count; matching-claim+trailing-text still does not tear down (locks the deliberate half too).

### [F04] Trailing whitespace on a numeric frontmatter value silently discards the user's cap
- **Location:** hooks/stop-hook.sh:77 (fm() strips no trailing space) → :86-90 (num10 regex rejects "5 " → default 0) → :258-262 (backstop overwrites); statusline/repete.sh:34-70 (same parser, renders capped loop as uncapped)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — reproduced: `max_iterations: 5␠` → file rewritten to `max_iterations: 25` with the backstop warning (probe t1, 2026-08-31).
- **Failure trigger:** hand-edited state file with a trailing space/tab after any numeric value (invisible in most editors). Value reads as malformed → num10 default. For max_iterations with context budget 0 that's cap 5 → 25 (5× the configured budget); with a context budget set, cap silently gone entirely; same for stale_limit/context_budget_lines.
- **Blast radius:** loop runs past the human's configured budget. Silent (the backstop message even looks intentional).
- **Evidence:** probe t1 output `max_iterations: 25` + safety-cap systemMessage.
- **Fix:** strip trailing `[[:space:]]*` in fm() (hook) and fmv (statusline) — one sed/awk tweak each; num10 stays strict.
- **Guardrail:** tests: hook keeps `max_iterations: 5␠` as 5 (no backstop); statusline renders rp[3/5] for a trailing-space max.

### [F05] marketplace.json is validated at release time only — the repo-HEAD install path can break while CI is green
- **Location:** tests/run-all.sh:16-17 and .github/workflows/ci.yml:18 (jq check covers plugin.json/statusline.json/hooks.json only); .github/workflows/release.yml:33 covers it
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — grep: `marketplace` appears in release.yml but not in run-all.sh/ci.yml (probe d).
- **Failure trigger:** a malformed edit to `.claude-plugin/marketplace.json` merges green; `README.md:178` tells users to install via `/plugin marketplace add betmoar/cc-repete-plugin`, which reads that file from repo HEAD — installs break until the next tag push surfaces it (or indefinitely).
- **Blast radius:** user-facing install failure; loud for the user, invisible to CI.
- **Evidence:** `grep -n marketplace tests/run-all.sh .github/workflows/ci.yml` → no matches; `.github/workflows/release.yml:33` lists it (probe d, 2026-08-31).
- **Fix:** add marketplace.json to the jq -e check in tests/run-all.sh and ci.yml (parity with release.yml).
- **Guardrail:** the check itself, in both files; couplings-table row updated to name all three sync sites.

### [F06] scripts/release-gate.mjs is untested, and its own comment claims a test-import guard that no test uses
- **Location:** scripts/release-gate.mjs:127-129 ("Only run the CLI … not when imported by tests" — no test imports it; grep over tests/ has zero hits); run-all.sh/ci.yml never execute it
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — grep `release-gate` across repo: only scripts/, release.yml, README, CHANGELOG.
- **Failure trigger:** any regression in gate()/extractSection ships silently and is first exercised on a tag push — the worst moment (release blocked or bad notes published).
- **Blast radius:** release pipeline breaks at tag time; recoverable but public-facing (notes) and trust-costing.
- **Evidence:** `grep -rn release-gate` → scripts/release-gate.mjs, .github/workflows/release.yml:28, README.md, CHANGELOG.md only; no file under tests/ imports it (grep 2026-08-31).
- **Fix:** add `tests/test-release-gate.mjs` (node:test, imports gate()/extractSection against fixtures incl. the F07 case) and wire into run-all.sh + ci.yml guarded on `command -v node`.
- **Guardrail:** the suite itself + CI wiring.

### [F07] extractSection truncates release notes at any body line starting with `[`
- **Location:** scripts/release-gate.mjs:36 (`const stop = /^## \[|^\[/m`)
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — reproduced: a `[NoLiMa] …` body line at column 0 cut the extracted section; "truncated: true" (probe rg-probe.mjs, 2026-08-31).
- **Failure trigger:** a CHANGELOG entry whose line begins with `[` (reference-style tag, link, "[MEASURED: …]" — the repo's own skills use that convention in prose). The stop regex means "next heading or link-ref block" but matches any `[`-leading line.
- **Blast radius:** silently truncated GitHub release body; gate still passes (notes non-empty).
- **Evidence:** rg-probe.mjs output: extracted section stops before the `[NoLiMa]` line; `truncated: true` (2026-08-31).
- **Fix:** tighten the stop to the link-reference shape: `/^## \[|^\[[^\]]+\]:\s/m`.
- **Guardrail:** case in the new release-gate test suite (F06).

### [F08] Lesson-card `hits` over 18 digits wraps negative in the catalog — rank inverted, garbage rendered
- **Location:** hooks/stop-hook.sh:189-190 (`[[ "$hits" =~ ^[0-9]+$ ]]` unbounded, then `$((10#$hits))`)
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — reproduced: 26-digit hits → catalog line `huge-hits [a] high hits:-2537764290115403777`, ranked below hits:5 (probe t5, 2026-08-31).
- **Failure trigger:** a hand-authored or agent-authored card with an absurd hits value; the same overflow num10 guards against everywhere else (its comment documents the wrap).
- **Blast radius:** cosmetic + ranking garble in the injected catalog; no crash (decision still block).
- **Evidence:** probe t5 catalog output line `huge-hits [a] high hits:-2537764290115403777`, ranked below the hits:5 card (2026-08-31).
- **Fix:** `hits="$(num10 "$(card_field "$f" hits)" 1)"` — reuse the existing guard.
- **Guardrail:** catalog test with a >18-digit hits card asserting sane rank + display.

### [F09] CLAUDE.md (the maintainer map) predates the release machinery — couplings and release steps missing
- **Location:** CLAUDE.md couplings table + "How to change the hook safely" step 5 vs. .github/workflows/release.yml, scripts/release-gate.mjs, tests/golden-default-reinject.sha, .claude-plugin/marketplace.json, docs/spec/
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — grep: none of release.yml / release-gate / golden sha / marketplace appear anywhere in CLAUDE.md; step 5 says bump plugin.json+README but the release gate also requires the newest CHANGELOG heading to match; the sync row names run-all↔ci.yml but release.yml re-lists the same checks as a third hand-synced site.
- **Failure trigger:** the next maintainer follows CLAUDE.md, bumps plugin.json+README only, pushes a tag → release gate fails; or changes the default re-inject, updates the golden by hand-derived pipeline or not at all.
- **Blast radius:** exactly the inheritor-floor failure this handoff doc exists to prevent.
- **Evidence:** `grep -c "release-gate\|release.yml\|golden\|marketplace" CLAUDE.md` → 0; CLAUDE.md "How to change the hook safely" step 5 names only plugin.json + README (read 2026-08-31).
- **Fix:** add couplings rows (release trio, golden SHA, marketplace manifests) and extend step 5 with the CHANGELOG entry + golden-regen step; note the three-way run-all/ci/release sync.
- **Guardrail:** doc-lock-style test asserting CLAUDE.md mentions release-gate + golden regen (mirrors the existing doc-lock block's approach).

### [F10] No tool regenerates tests/golden-default-reinject.sha — a deliberate re-inject change requires hand-deriving the exact pipeline
- **Location:** tests/test-hooks.sh:601-622 (golden block) — the sha is consumed, never produced by any script
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — grep `golden-default-reinject` matches only the test and the sha file.
- **Failure trigger:** any deliberate change to the default re-inject (new rule, reworded protocol). The maintainer must reconstruct `run fixture | jq -r .reason | shasum | cut -d" " -f1` from the test source; an inexact reconstruction (wrong fixture, wrong session id) writes a wrong golden that fails forever or, worse, locks a wrong value.
- **Blast radius:** workflow footgun; converts directly into a Phase-4 tool.
- **Evidence:** `grep -rn golden-default-reinject` → tests/test-hooks.sh:622 (consumer) and the .sha file itself only (2026-08-31).
- **Fix:** `tests/regen-golden.sh` that rebuilds the exact fixture and rewrites the sha + prints the old/new diff; reference it from the golden test's comment and CLAUDE.md.
- **Guardrail:** the tool itself; the golden test failure message points at it.

- 2026-08-31 P2: self-verification pass — all 10 findings re-checked against code/probes this session; none dropped, no confidence downgrades. lint_findings.py → 0 problems. EXIT CRITERIA met (final sweep surfaced nothing new above P3). Cursor → P3.
- 2026-08-31 P3 plan: fix F01–F04, F08 in hook (+F04 statusline), F07 in release-gate; add tests for each; F05 run-all+ci; F06 new node test suite wired in; F10 regen tool; F09 + CHANGELOG/README/version 0.2.2 as docs pass. Golden SHA must remain byte-identical (all fixes are off-default-path); regen tool will prove it.

- 2026-08-31 P3: fixes landed for F01,F02,F03(reset half),F04,F05,F06,F07,F08,F10 + F09 docs. Suite delta: hooks 237/0 → 256/0, statusline 24/0 → 25/0, +9 node:test release-gate cases, ALL SUITES GREEN. Golden SHA byte-identical (regen-golden: "unchanged"). Each P2 fix re-verified against its original repro (F01 no-block+warning as nobody/555; F02 body marker present; F03 stale_count preserved at 2; F04 cap kept at 5).
- 2026-08-31 P3: incident during comment-tagging sed pass — two hook comment lines mangled (merged/duplicated); caught by adversarial diff re-read, repaired, suite re-run green. No code lines affected at any point (comments only; bash -n green throughout).
- 2026-08-31 P4: guardrails RUN GREEN — A-F01/02/03/04/08 test blocks, 3 new doc-lock asserts (CLAUDE.md names release-gate + regen-golden), tests/test-release-gate.mjs, marketplace jq checks in run-all+ci. Tools: tests/regen-golden.sh. Context transfer: CLAUDE.md couplings +4 rows, failure-philosophy +2 bullets, step-5 release flow, backlog #6 added. Version 0.2.2 + CHANGELOG section (release-gate dry-run OK).
- 2026-08-31 P4: EXIT CRITERIA met; final self-verification pass done (findings ledger lint 0 problems; all claims trace to run output in this log). Cursor → DONE. STOP CONDITION 5: emitting final output, then commit+push+draft PR under the session's standing authorization.

- 2026-08-31 post-review (Copilot round on PR #20, all 3 findings verified real before fixing): (1) set_fm on a BOM'd file wrote into an EOF pseudo-block reads never saw — counter frozen, Stop blocked forever with the cap unreachable (reproduced: 3 Stops all "iteration 2"); fixed by de-BOM-once-on-disk at startup (rewrite failure degrades into the F01 bail-open paths); locked by 4 new asserts incl. counter-advances-on-next-Stop. (2) the F07 link-ref stop condition was shadowed by GOOD_CHANGELOG's later heading — new no-later-heading fixture locks it. (3) release.yml was missing the release-gate test step this PR added to run-all/ci — added (three-way sync restored). Suites: hooks 260/0, statusline 25/0, release-gate 10/10, golden unchanged.
