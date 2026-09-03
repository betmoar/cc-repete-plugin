# cc-repete — maintainer handoff

This file is the mental model for whoever changes this plugin next. It encodes the
judgment behind the code, not just its layout. Read it before touching
`hooks/stop-hook.sh`; the couplings table before touching anything else.

**Before every commit: `bash tests/run-all.sh`.** There is no build step and no type
system — the test suites plus shellcheck are the entire safety net, and CI
(`.github/workflows/ci.yml`) enforces the same checks. Every behavior change ships with
a `ck` assertion; the invariant blocks at the bottom of `tests/test-hooks.sh` pin
documented guarantees — if one fails, fix the hook, never the test.

## What this is

A Claude Code plugin that turns the `Stop` hook into a loop engine. When a loop is
active, every Stop attempt is intercepted and the hook makes a decision: tear down
(mission done), yield to the human (checkpoint / safety budget), or block the stop and
re-inject the working brief (continue). Everything else — commands, templates, skills —
exists to set up, steer, or explain that one decision.

Two kinds of code live here and they fail differently:

- **Shell** (`hooks/stop-hook.sh`, `statusline/repete.sh`) — executed mechanically.
  Bugs here are real bugs; this is where the tests point.
- **Prompt-code** (`commands/*.md`, `skills/*/SKILL.md`, `templates/*.md`) — executed
  by a model reading it. There is no validation layer; precision of wording IS the
  implementation. Keep steps imperative, numbered, and unambiguous. When you change
  hook behavior, grep the prompt-code for stale descriptions of it — the commands and
  README promise behavior the hook must actually have, and vice versa.

## The load-bearing core (ranked by blast radius)

1. **`hooks/stop-hook.sh` — the decision order.** The checks run in a deliberate
   sequence, and most of the subtle guarantees live in that ordering, not in any single
   check: state-file exists → jq exists (else fail open) → `active` → terminal/paused
   statuses exit → session isolation (stamp on first sight) → no-budget backstop
   (any active loop with both budgets 0 — gated included) → read the last text-bearing
   main-thread assistant message of the CURRENT turn → sentinel handling (suppressed
   while `summarizing`; checkpoint beats done; autonomous ignores checkpoint; a
   mismatched done-claim counts toward `stale_count`, annotates the re-inject, and at
   `stale_limit` consecutive mismatches yields `paused-stale`) → max-iterations yield
   (skipped while `summarizing`) → context-budget two-step → stranded-`summarizing`
   recovery (re-applies the cap) → bump iteration → assemble re-inject (body →
   [stale note] → catalog → constitution → [gauntlet rules] → protocol last). Do not
   reorder without re-deriving why each earlier check must precede the later ones —
   the inline comments state the reason at each site.
2. **`.repete/loop.local.md` frontmatter schema** — the shared contract between the
   hook, the statusline, all four commands, and the tests. Adding a key means updating:
   the template, `commands/repete.md` scaffold instructions, the hook's `fm` reads, and
   `/repete-status` rendering.
3. **The two sentinels** — `<repete-done>` / `<repete-checkpoint>` literals appear in
   the hook, `templates/protocol.md`, all commands, the README, and both skills.
   Renaming one is a cross-cutting change; grep for both spellings everywhere.
4. **`templates/protocol.md`** — injected every iteration with literal `${PHASE}`/
   `${NEXT}` tokens substituted by the hook (they are NOT shell expansions; the
   single-quoting in the hook is deliberate). If the template is unreadable the hook
   falls back to an inline core — the loop must never lose its sentinels.
5. **The status state machine** — `running → summarizing → paused-context`,
   `running → paused-checkpoint | paused-max | paused-stale`, terminal `done | cancelled`.
   That list is exhaustive: bare `paused` was removed in v0.2.1 (no writer, no resume
   branch — dead surface, issue #12), and a test locks it out of the early-exit case.
   Adding a status means updating: the hook's early-exit case, `/repete-status`'s "what
   to do next" map, and `/repete-continue`'s branch list.
6. **What a loop PUBLISHES to sibling plugins** (issue #27) — two contracts this repo
   emits without reading the consumers. Neither is a dependency; both are one-way
   interfaces, invisible from inside this tree:
   - **`.repete/loop.local.md` is a read API.** At minimum the path, the `active` key,
     and the value form `active: true` — cc-reload's `repete_active()` greps exactly
     that pattern (bare grep, whole file) and stands down on a hit. Renaming the key,
     moving the file, or changing the value shape breaks a sibling SILENTLY: green
     suite here, and cc-reload keeps running alongside a live loop — two plugins
     fighting over the context budget, the exact outcome its stand-down prevents.
     Locked by the `#27` test block, which greps from the consumer's side. Their
     reader is looser than ours (matches body prose quoting `active: true`; our own
     reads scope to the first frontmatter block — the C1 trap). That divergence is
     theirs to fix; ours is to keep the first-block form stable.
   - **Blocking `Stop` keeps `stop_hook_active` true for the session.** The hook never
     reads that field (correct — a loop engine standing down on it would end after one
     iteration), but a hook-forced continuation sets it on every subsequent `Stop`,
     and OTHER plugins' Stop hooks receive it. cc-operator's Stop gate uses it as a
     private loop guard and is silently disarmed for the whole window of an active
     loop (betmoar/cc-operator-plugin#116). If you ever change when this hook blocks,
     you are changing that reach.
   If a third contract ever emerges (another file another plugin greps), document it
   here and pin it the same way.

## Failure philosophy (the one rule)

**The hook may only fail OPEN.** Every uncertain situation must resolve toward "let the
Stop through" or "keep looping within budgets" — never toward trapping the user or
tearing the loop down on a false positive. Concrete embodiments:

- No `jq` → exit 0 (can't steer, so don't intervene) — but since v0.2.1 an ACTIVE loop
  gets one hand-built JSON warning first (`.repete/.warned-nojq` marks it), because
  "inert with zero signal" is a bad kind of open. Still exit 0 on every branch, marker
  write failure included.
- Unparseable frontmatter values → numeric defaults, flags default off.
- Malformed transcript lines → skipped per line (`fromjson?`), never abort the parse; a
  parse abort would blind sentinel detection and block every Stop (fail-closed — the
  bug fixed in v0.1.4).
- Done-goal match is deliberately strict (exact string, whitespace-normalized): the
  cheap failure is burning iterations, the expensive one is a false teardown.
- **A mismatched done-claim is counted and fed back, not silent** (v0.2.0): `stale_count`
  bumps, a rejection note rides the next re-inject, and `stale_limit` (default 3, `0` off,
  unparseable → 3 — fail toward the human) consecutive mismatches yield `paused-stale`. A
  plain work turn (no done sentinel) resets the count — deliberate, so stage-wise loops
  don't false-trip. The yield is budget-class: it stops even autonomous loops, because a
  loop that repeatedly false-claims done is exactly the failure it exists to catch.
- A stray sentinel during `summarizing` is ignored: the budget two-step owns that Stop.
- **A failed state write fails OPEN, never closed** (audit F01): if `set_fm` cannot
  persist (read-only `.repete/`, disk full), the two paths that BLOCK — budget pass-1
  and the iteration bump — bail with a warning and let the Stop through. Blocking is
  only allowed when progress can be persisted. The warning repeats while writes keep
  failing — noisy, never trapping.
- **A decision the hook really made must be PERSISTED, or the message must not claim it**
  (v0.2.3, issue #21): `set_fm_or_warn` guards every write whose message promises
  persistence. On failure: never emit the claimed outcome, never set `decision:block`,
  warn, exit 0. It must never become a new blocking path — the one thing this fix could
  get wrong.
  **Corollary — a multi-write decision must be ordered so its PARTIAL is the safe
  state.** The teardown writes `active: false` BEFORE `status: done`: reversed, the
  partial is `done` + `active: true`, read as finished while statusline and
  `/repete-status` (keyed on `active`) render a healthy running loop. Shipped order's
  partial is an inert loop. Any future two-write decision picks its order the same way
  (locked by the `#21 order` test block).
- **A turn whose done-claim sits in an EARLIER text entry is NEUTRAL** (audit F03): the
  last text entry still wins (locked v0.2.1 semantics — no teardown, no count), but such
  a turn no longer RESETS `stale_count` — pre-fix, an agent that habitually appended
  text after claims could never trip `paused-stale`. Only a turn with no done sentinel
  anywhere resets. Perl missing → reads as "no sentinel elsewhere" → reset.
- **A sentinel the agent really emitted must be SEEN** (v0.2.1, issue #18). Missing one
  looks fail-open but is a trap in practice: a correct done-claim the hook cannot see
  never tears down, never counts stale, never reaches the human — the loop spins to its
  budget with the exit condition satisfied. So sentinel extraction reads the last
  text-bearing entry of the turn, not the last entry.

If you add a check, decide its failure direction first and write it in a comment.

## Couplings — if you touch X, update Y

| You changed | You must also update | Enforced by |
| --- | --- | --- |
| `templates/handoff.md` section headings | Hook pass-1 re-inject brief AND pass-2 scaffolding-strip pattern | test: "Coupling lock: handoff headings" |
| `templates/protocol.md` placeholders | Hook substitution + `PROTO_FALLBACK` | test: "Protocol placeholders" |
| `loop.local.md` frontmatter keys | Hook `fm` reads, `commands/repete.md` scaffold, `/repete-status`, test `scaffold()` | tests use the schema throughout |
| Status values | Hook early-exit case, `/repete-continue` branches, `/repete-status` map, statusline `case` (renders `·ck/·ctx/·max/·stale` markers — a new status silently renders as healthy) | tests: paused/terminal blocks |
| `stale_count`/`stale_limit` keys | Hook `fm` reads + mismatch branch, `templates/loop.local.md`, `/repete` scaffold prose, `/repete-status` budgets line, `/repete-continue` paused-stale branch | tests: stale blocks |
| `gauntlet`/`reference`/`bar` keys | Hook `fm` read + gauntlet injection block, `templates/loop.local.md`, `/repete` optional-features, `/repete-status` gauntlet section, tests scaffold comment | tests: gauntlet blocks |
| `templates/gauntlet.md` content | Hook injection + `GAUNTLET_FALLBACK` + the coupling-lock phrases (`parts.md`, `critic`, `final integration`) | test: "Coupling lock: gauntlet" |
| Sentinel strings | Hook + README always; `<repete-done>` also protocol + `skills/repete-loops/SKILL.md` + /repete; `<repete-checkpoint>` also that skill + /repete-continue (NOT protocol.md — the frozen core stays quiet; the rule rides RULES_EXTRA) | tests: doc-lock block |
| Adding a second skill under `skills/` | Nothing mechanical — but the plugin ships exactly ONE by design (v0.2.3), locked by test. Two skills competed for the same triggers, so Claude consulted one and silently missed the other half; descriptions sit in context every session. A second skill must earn a genuinely disjoint trigger surface | test: "exactly one skill ships" |
| `skills/repete-loops/references/*.md` filenames | The pointers in that skill's SKILL.md (§1, §5, closing list) — a missed rename is a dangling path | test: doc-lock references |
| `templates/lesson-card.md` frontmatter (incl. inline `#` comments) | `card_field`'s comment-stripping | test: catalog block |
| `hooks/promote.sh` keys or behavior | `commands/repete-continue.md` step 4 invocation, `tests/test-promote.sh`, frontmatter-schema row (promote writes 6 keys) | test: `tests/test-promote.sh` |
| A new test suite file under `tests/` | `tests/run-all.sh` AND `.github/workflows/ci.yml` AND `.github/workflows/release.yml` — three sites, by hand | not enforced — a suite missing from CI never runs on a tag |
| The state-file read API siblings grep for (path `.repete/loop.local.md`, key `active`, value `true` in the FIRST frontmatter block) | Nothing in-tree — but cc-reload's `repete_active()` greps it to stand down, so a rename/move/value-shape change breaks a sibling silently. Update core item 6 and notify the sibling repo. Do not "fix" the divergence by loosening our reads — their bare grep matching body prose is their bug | test: `#27` blocks |
| The scan jq program (`TURN_SCAN_JQ`) | Nothing — defined ONCE, reused by all three paths (fast path, mktemp fallback, growth loop). It was three verbatim copies; re-inlining lets the paths silently disagree | tests: window-scan + `#18` |
| Window sizing (`WINDOW_LINES`, `WINDOW_GROWTH`) | Nothing mechanical — initial size stays above the documented 500-sidechain hazard; growth predicate stays "contains a turn boundary" (see landmine) | tests: window-scan blocks |
| Transcript scan shape (`$turn_start`, text-bearing pick) | The `#18` block — both directions (sentinel behind a tool tail IS seen; a spent sentinel from a previous turn is NOT) AND every observed user-row shape that decides the boundary: bare `tool_result`, plain string, `text`, `image+text`, mixed `tool_result`+text, sidechain. PLUS the `#24` decision-lock (retraction/wrap-up after a claim → no teardown — the measured 70/30 split) and the Stop-input field list (incl. `last_assistant_message`, no token field) | tests: `#18` + `#24` blocks |
| `.repete/.warned-nojq` marker path | Hook no-jq branch + the warning text that names it for deletion | tests: `#7` blocks |
| Hook behavior described in README/commands/skills | The prose in all three | not enforced — grep manually |
| Behavior a `docs/spec/*` file describes (`stale-detection.md` → `stale_count`/`stale_limit`; `gauntlet-mode.md` → `gauntlet`/`reference`/`bar`) | Append a `> Refined in vX.Y.Z` note to the superseded spec section, pointing at the live logic — do NOT rewrite the record | not enforced — the spec is a design record, the hook is authoritative |
| `tests/run-all.sh` checks | `.github/workflows/ci.yml` AND `.github/workflows/release.yml` (three sites, by hand) | not enforced |
| Default re-inject content (protocol wording, rules, assembly) | `tests/golden-default-reinject.sha` — regenerate with `bash tests/regen-golden.sh` (fixture mirrors the golden block; keep both in sync) | test: golden block |
| `plugin.json` version | Newest `## [x.y.z]` CHANGELOG heading + README version line + the release tag | `scripts/release-gate.mjs`; `tests/test-release-gate.mjs` |
| `.claude-plugin/marketplace.json` | jq validity check in run-all.sh + ci.yml + release.yml (serves `/plugin marketplace add` from repo HEAD) | run-all/ci jq step |

## Landmines (non-obvious decisions that look like mistakes)

Full reasoning lives at each site's comment and in the linked test blocks; these are
the rules with their one-line why.

- **`set -uo pipefail` without `-e` is deliberate** — much of the hook treats non-zero
  as data (grep misses, perl probes). `-e` breaks it subtly.
- **`STALE_NOTE` is initialized OUTSIDE the `summarizing` guard** — the summarizing
  path skips the sentinel block but still flows through re-inject assembly, which reads
  `STALE_NOTE`; under `set -u` an init inside the guard crashes every summarizing Stop.
  Same trap for any variable set in a guarded block but consumed after it.
- **`fm()` reads the FIRST occurrence of a key; test `scaffold()` only APPENDS** —
  seeded default + appended override = two keys, hook silently reads the default (the
  C1 trap, rediscovered for `gauntlet`). Seed nothing you intend to override; use
  `setstate`.
- **`GAUNTLET_FALLBACK` mirrors `PROTO_FALLBACK`** (critique pointer first-line-only,
  appended AFTER template/fallback resolution so both paths carry it): the loop must
  never silently lose working rules, and critique bodies stay metadata — injecting
  them every iteration re-creates the context rot the catalog rules fight.
- **`set_fm` updates only the FIRST frontmatter block, appends missing keys before the
  closing `---`** (C1/C2/C3). Value travels via `ENVIRON["REPETE_FM_VAL"]`, not
  `awk -v` — `-v` runs escape processing, a literal `\` was eaten (#10). The `END`
  block is the fenceless-file path (#11): key appended at EOF, `---` written after it;
  EOF is the only possible landing spot. On a fenceless file the body ends up above
  the repaired fence — byte-intact (locked) but outside `PAYLOAD_BODY`, where it
  already was. Do not "improve" by guessing the split: promoting body prose into live
  frontmatter is the strictly worse failure.
- **`hooks/promote.sh` fails LOUD — the opposite of the hook's one rule, deliberately.**
  Human-gated (one call from `/repete-continue` after approval), not an unattended
  Stop path, so a silent partial write IS the defect #8 fixes. Do not harmonize with
  `set_fm`'s fail-open. Mirrors C1/C2/C3 + #11 for six keys; does NOT touch the body.
  De-BOMs before reading (v0.2.3) — a BOM glues to the opening `---`, the phase read
  returns empty AND the writer's `f==1` never opens; if the BOM can't be stripped it
  REFUSES rather than write mis-scoped.
- **`od -An -tx1` pads with variable whitespace** (two spaces between bytes on BSD,
  leading indent) — `grep -q 'ef bb bf'` against raw output silently never matches.
  Squeeze with `tr -s '[:space:]' ' '` and match `" ef bb bf "*`. Was live in
  promote.sh for one commit; caught only because tests ran red-first.
- **Iteration semantics:** `iteration` counts completed work turns; cap check is `>=`
  before the bump, so `max_iterations: 3` = exactly 3 work turns. The handoff
  (`summarizing`) turn is free — no bump.
- **`summarizing` owns its Stop.** Sentinels and the iteration cap are suppressed in
  it; stranded-recovery re-applies the cap on exit. This keeps the /clear flow
  undivertable; don't "simplify" the suppression away.
- **A checkpoint beats a done in the same message (I2)** — the human-gated path is the
  safe one. Autonomous forces `HAS_CHECKPOINT=0` so only done/budgets stop it.
- **The autonomous backstop** (both budgets 0 → stamp `max_iterations: 25`) must
  persist (C3) or it warns every iteration. Since the 2026-08 audit it applies to
  GATED loops too — a gated loop whose agent never checkpoints has no other mechanical
  stop (51 consecutive iterations reproduced). Any active loop with both budgets 0
  gets the cap.
- **Gauntlet rules require `reference:` AND `bar:` non-empty** (F10): builder/critic
  rules with nothing to reference is iteration-burning theater.
- **Constitution/handoff "emptiness" tests strip scaffolding literally** — HTML
  comments, the template's exact headings, whole-line `<placeholders>`. Stripping any
  `#`-leading line misclassifies real content like "# TODO finish parser".
- **Body extraction prints-before-increment (I1)** so a `---` rule inside the body is
  preserved, not swallowed.

### Window scan (issue #9) — four rules, one class of enemy

An optimization may never be worse than the thing it replaced. Three instances of the
same class shipped and were caught in review (the `wc -l` undercount, the unchecked
`tail`, a failing `grep -c` read as "short window"); the rules below are the residue.

- **Grow on "contains a turn boundary", NOT "found assistant text"** — text predicate
  forces a full read on tool-only turns, and worse: a window with text but no boundary
  falls back `$turn_start=-1`, scans into the PREVIOUS turn, re-fires a spent sentinel
  (fail-closed through a different door). The boundary predicate is safe because the
  window is a `tail` SUFFIX: containing any boundary ⇒ containing the LAST one. Terminal
  condition: `tail` returns fewer lines than requested.
- **Count window lines with `grep -c ''`, NEVER `wc -l`** — `wc -l` counts newlines;
  a missing trailing newline (routine mid-append shape) makes the window look short,
  growth stops one line early, a real `<repete-done>` goes invisible. Suite was green
  while it lived. Also the fastest counter (0.00s vs 0.04s at 100k lines).
- **Validate every count with `^[0-9]+$`** — `[[ "$x" -le N ]]` on non-numeric is a
  bash runtime error; under `set -u` the hook aborts with no JSON at all. Invalid
  count → direct read, never a guess.
- **Every external command the scan depends on (`tail`, `grep -c`, `mktemp`) falls
  back to the full read on failure** — each is a NEW way to lose a sentinel the
  pre-window code saw. A count failing is NOT the same fact as a short window.
- **Bound CUMULATIVE window work, not the last doubling** — growth parses the SUM of
  windows (geometric waste); the live rule stops when parsed-so-far + next window
  exceeds a QUARTER of the file, and the direct-read guard `4 * WINDOW_LINES` kills
  the just-over-one-window case. Together: ≤1.25x at every size (simulated
  2001..400000 lines). Perf claims are hand-measured — re-measure, don't trust the
  suite; CI pins the ANSWER, never wall-clock.
- **Test the window's MECHANISM, not just its answer** — every status/decision
  assertion passes whether the early exit fired or the loop fell through to a full
  read (proven by mutating `FOUND_BOUNDARY=false`, 12/12 still green). The lock is an
  INVOCATION COUNT via a `jq` PATH shim. KNOWN UNTESTED: `PARSED_LINES` accumulation
  (smallest fixture ~50MB — re-run the simulation if you touch the growth arithmetic).

### Sentinel extraction (issue #18)

- **Read the last TEXT-BEARING assistant entry of the current turn, not the last
  entry** — a done-claim followed by a tool call ends with a `tool_use`-only entry;
  the old `| last` read `""`, blanking the claim: no teardown, no stale count, zero
  feedback, forever. The scan is bounded to the current turn: everything after the
  last main-thread `user` entry with a NON-`tool_result` block (tool results are
  `role:user` too; a mixed tool_result+text row IS a boundary — observed shapes
  18801/1939/207/23 across 75 real transcripts). `.text | strings` drops non-string
  `.text` — a jq runtime error aborts the WHOLE program, blinding detection.
- **Last-entry-wins is SETTLED, not default** (#24, measured 2026-09-03 over 756
  sessions): of done-claiming turns, 85% claim in the last text entry (seen), 15%
  earlier (invisible); of the earlier-claim turns, 70% are retracted/qualified by
  later text, 30% neutral wrap-up. Joining all entries honors the 30% by tearing down
  on the 70% — the expensive direction. Locked in the `#24` decision-lock block;
  flipping it means flipping both assertions together.
- **The no-jq warning is hand-built JSON** (#7) — `emit()` needs jq; that branch
  printf's a fixed literal and marks `.repete/.warned-nojq` (nothing clears it; the
  message names the path for deletion). Gated on `active: true` via an inline awk
  scoped to the first frontmatter block, not a bare grep (the C1 trap — body prose
  quoting `active: true` warned about finished loops).
- **Lesson catalog is metadata-only by design** — injecting card bodies every
  iteration is the exact context-rot source the design fights. One line per card.

## How to change the hook safely

1. Write the failing `ck` test first in `tests/test-hooks.sh` (copy an existing block;
   `scaffold`/`setstate`/`mktx`/`run` are the whole harness — note `scaffold` seeds a
   lesson card, remove it if your fixture ranks cards).
2. Make the smallest change that passes; state the failure direction in a comment.
3. `bash tests/run-all.sh` — all suites plus shellcheck must be green. If you changed
   the default re-inject deliberately, `bash tests/regen-golden.sh` and commit the new
   sha WITH the change.
4. Grep commands/README/skills **and `docs/spec/`** for descriptions of the behavior you
   changed. Append a `> Refined in vX.Y.Z` note naming the live logic; never rewrite
   the record to match the code (that is how the F03 stale-reset drift survived a
   review round).
5. Bump `version` in `.claude-plugin/plugin.json`, the README's version line, AND add
   the matching `## [x.y.z]` entry newest in CHANGELOG.md — the release is tag-driven
   and `scripts/release-gate.mjs` fails any tag where the trio disagrees; the CHANGELOG
   section becomes the release body.

## Residual risks / backlog (prioritized, with context)

Settled/shipped items keep one line with their pointer; the issue trail and CHANGELOG
carry the history.

1. **Checkpoint promotion SHIPPED v0.2.3 (#8)** — `hooks/promote.sh`, six keys atomic.
   Residue: the three non-checkpoint resume branches still hand-edit `status`/`session_id`;
   a `--resume-only` flag would fold them in, not done because those branches need a
   human judgment step promote.sh cannot encode.
2. **Transcript parse trusts `.message.role`/`.type` shape.** If the format moves
   upstream, the boundary degrades to "scan everything" (pre-v0.2.1 scope, fail-open) —
   watch release notes, re-check `$turn_start`. **Escape hatch measured 2026-09-03**:
   Stop input carries `last_assistant_message` (harness-provided final assistant text);
   field list pinned in the `#24` test block. No token/context field exists.
3. **Lines-vs-tokens SETTLED (#15, 2026-09-03)** — no token field in Stop input
   (measured); bytes-per-line spans 1.1–15.7 KB across 34 real transcripts, so bytes
   are the same noise at a larger unit. Lines stay. Record: `docs/spec/stale-detection.md`
   appendix. Reopen only if the harness ships a tokens field.
4. **v2/v3 roadmap (#13/#14)** — evaluable specs exist (2026-09-03):
   `docs/spec/phased-missions.md` (#13, implementable), `docs/spec/global-lesson-store.md`
   (#14, spec-only by design — promotion needs cross-project recurrence data that does
   not exist yet; shipping early would promote on noise). Proposals, not approved designs.
5. **Per-Stop scan cost SHIPPED (#9)** — windowed scan; see the window landmines.
   Measured: 100k-line 0.85s → 0.14s; deep-boundary cases within +0.17s of old; the
   cited ~2.8s never reproduced. Residue: `fm()` fork count (~60/Stop) is
   millisecond-scale — batch opportunistically, never urgently.
6. **Multi-entry-turn visibility SETTLED (#24, 2026-09-03): last-entry-wins STAYS** —
   measured 756 sessions: 85% visible / 15% invisible; of earlier-claim turns 70%
   retracted, 30% wrap-up. Joining honors the 30% by tearing down on the 70%. Locked in
   the `#24` decision-lock block; record in `docs/spec/stale-detection.md` appendix.
   Residue: a future switch to `last_assistant_message` must preserve the `#18`/`#24`
   invariants.
7. **Audit cut still open** (2026-08-16): the "keep/!update" garble lineage in
   repete-continue step 4 (wording fixed, watch regressions). The rest shipped in
   v0.2.1: #10 #11 #12 #7 #16 #17 (the `jq -e` assertion convention — applied to new
   assertions, migrated opportunistically).
8. **`set_fm` announce bug SHIPPED v0.2.3 (#21)** — `set_fm_or_warn` guards every
   persistence-promising write. RESIDUE, open: `set_fm` orphans its `.tmp.$$` when
   `mv` fails — no `|| rm -f`. Cosmetic, but litters `.repete/` on a full disk.
9. **Release-notes truncation SHIPPED v0.2.3 (#22)** — stop pattern requires the URL shape.
10. **`docs/spec/*` couplings row SHIPPED v0.2.3 (#23)** — safe-change step 4 names it;
    each spec declares itself a design record.
