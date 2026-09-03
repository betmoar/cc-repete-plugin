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
   (any active loop with both budgets 0 — gated included) → read the last
   text-bearing main-thread assistant message of the CURRENT turn → sentinel handling (suppressed
   while `summarizing`; checkpoint beats done; autonomous ignores checkpoint; a
   mismatched done-claim counts toward `stale_count`, annotates the re-inject, and at
   `stale_limit` consecutive mismatches yields `paused-stale`) → max-
   iterations yield (skipped while `summarizing`) → context-budget two-step → stranded-
   `summarizing` recovery (re-applies the cap) → bump iteration → assemble re-inject
   (body → [stale note] → catalog → constitution → [gauntlet rules] → protocol last). Do
   not reorder without re-deriving why each earlier check must precede the later ones —
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
   Adding a status means updating: the hook's early-exit case, `/repete-status`'s "what to do
   next" map, and `/repete-continue`'s branch list.
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
  "inert with zero signal" is a bad kind of open: the user sees a loop that never runs
  and no reason why. Still exit 0 on every branch, marker write failure included.
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
- **A failed state write fails OPEN, never closed** (2026-08-31 audit F01): if `set_fm`
  cannot persist (read-only `.repete/`, disk full), the two paths that BLOCK — budget
  pass-1 and the iteration bump — bail with a warning and let the Stop through. Without
  this, pass-1 re-fired on every Stop forever (status never advanced, iteration never
  bumped, so no budget could fire — reproduced). Blocking is only allowed when progress
  can be persisted. The warning repeats while writes keep failing (no marker can be
  written either) — noisy, never trapping.
- **A decision the hook really made must be PERSISTED, or the message must not claim it**
  (v0.2.3, issue #21). The mirror of the sentinel rule below. ~10 `set_fm` calls — `done`
  - `active false`, both `stale_count` writes, every `paused-*`, the stranded-`summarizing`
    recovery — discarded the return value and printed a confident outcome regardless. On a
    read-only `.repete/` the user was told "mission goal met" while state stayed
    `active: true / status: running`, and a later Stop hijacked an unrelated turn
    (reproduced on v0.2.1 and v0.2.2). `set_fm_or_warn` generalizes the guard the two F01
    sites already had. Failure direction: never emit the claimed outcome, never set
    `decision:block`, warn that state could not be saved, exit 0. It must never become a
    new blocking path — that is the one thing this fix could get wrong.
    **Corollary — a multi-write decision must be ordered so its PARTIAL is the safe state.**
    `set_fm_or_warn` exits on the first failure, so a two-write decision can only fail as
    "write 1 landed, write 2 did not". The teardown therefore writes `active: false` BEFORE
    `status: done`: reversed, that partial is `done` + `active: true`, which the hook reads
    as finished while the statusline and `/repete-status` (both keyed on `active`) render a
    healthy running loop. In the shipped order the partial is an inert loop — the ACTIVE gate
    exits, the statusline prints nothing. Any future decision that needs two writes must pick
    its order the same way (locked by the `#21 order` test block).
- **A turn whose done-claim sits in an EARLIER text entry is NEUTRAL** (audit F03): the
  last text entry still wins (locked v0.2.1 semantics — no teardown, no count), but such
  a turn no longer RESETS `stale_count` — pre-fix, an agent that habitually appended text
  after claims could never trip `paused-stale`. Only a turn with no done sentinel
  anywhere resets. Perl missing → reads as "no sentinel elsewhere" → reset (pre-existing
  direction).
- **A sentinel the agent really emitted must be SEEN** (v0.2.1, issue #18). Missing one
  looks fail-open (the loop keeps going) but is a trap in practice: a correct done-claim
  that the hook cannot see never tears down, never counts as stale, and never reaches the
  human — the loop spins to its budget with the exit condition already satisfied. So
  sentinel extraction reads the last text-bearing entry of the turn, not the last entry.

If you add a check, decide its failure direction first and write it in a comment.

## Couplings — if you touch X, update Y

| You changed                                                                                                                                         | You must also update                                                                                                                                                                                                                                                                                                                                                                                                | Enforced by                                                                          |
| --------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `templates/handoff.md` section headings                                                                                                             | Hook pass-1 re-inject brief AND pass-2 scaffolding-strip pattern                                                                                                                                                                                                                                                                                                                                                    | test: "Coupling lock: templates/handoff.md headings"                                 |
| `templates/protocol.md` placeholders                                                                                                                | Hook substitution + `PROTO_FALLBACK`                                                                                                                                                                                                                                                                                                                                                                                | test: "Protocol placeholders"                                                        |
| `loop.local.md` frontmatter keys                                                                                                                    | Hook `fm` reads, `commands/repete.md` scaffold, `/repete-status`, test `scaffold()`                                                                                                                                                                                                                                                                                                                                 | tests use the schema throughout                                                      |
| Status values                                                                                                                                       | Hook early-exit case, `/repete-continue` branches, `/repete-status` map, statusline `case` (renders `·ck/·ctx/·max/·stale` markers — a new status silently renders as healthy)                                                                                                                                                                                                                                      | tests: paused/terminal blocks                                                        |
| `stale_count`/`stale_limit` keys                                                                                                                    | Hook `fm` reads + mismatch branch, `templates/loop.local.md`, `/repete` scaffold prose, `/repete-status` budgets line, `/repete-continue` paused-stale branch                                                                                                                                                                                                                                                       | tests: stale blocks                                                                  |
| `gauntlet`/`reference`/`bar` keys                                                                                                                   | Hook `fm` read + gauntlet injection block, `templates/loop.local.md`, `/repete` optional-features, `/repete-status` gauntlet section, tests scaffold comment                                                                                                                                                                                                                                                        | tests: gauntlet blocks                                                               |
| `templates/gauntlet.md` content                                                                                                                     | Hook injection + `GAUNTLET_FALLBACK` + the test coupling-lock phrases (`parts.md`, `critic`, `final integration`)                                                                                                                                                                                                                                                                                                   | test: "Coupling lock: templates/gauntlet.md"                                         |
| Sentinel strings                                                                                                                                    | Hook + README always; `<repete-done>` also protocol + `skills/repete-loops/SKILL.md` + /repete; `<repete-checkpoint>` also that skill + /repete-continue (NOT protocol.md — the frozen core stays quiet; the rule rides RULES_EXTRA)                                                                                                                                                                                | tests: doc-lock block                                                                |
| Adding a second skill under `skills/`                                                                                                               | Nothing mechanical — but the plugin ships exactly ONE by design (v0.2.3), and a test locks the count. Two skills competed for the same triggers ("autonomous loop", "context rot"), so Claude consulted one and silently missed the other half; descriptions sit in context every session, so the cost was permanent. A second skill must earn a genuinely disjoint trigger surface, not re-split this one by topic | test: "doc-lock: exactly one skill ships"                                            |
| `skills/repete-loops/references/*.md` filenames                                                                                                     | The pointers in that skill's SKILL.md (§1, §5, and the closing list) — a rename that misses one leaves the model following a dangling path                                                                                                                                                                                                                                                                          | test: doc-lock references block                                                      |
| `templates/lesson-card.md` frontmatter (incl. inline `#` comments)                                                                                  | `card_field`'s comment-stripping                                                                                                                                                                                                                                                                                                                                                                                    | test: catalog block                                                                  |
| `hooks/promote.sh` keys or behavior                                                                                                                 | `commands/repete-continue.md` step 4 invocation, `tests/test-promote.sh`, and the frontmatter-schema row above (promote writes 6 of those keys)                                                                                                                                                                                                                                                                     | test: `tests/test-promote.sh`                                                        |
| A new test suite file under `tests/`                                                                                                                | `tests/run-all.sh` AND `.github/workflows/ci.yml` AND `.github/workflows/release.yml` — three sites, all by hand                                                                                                                                                                                                                                                                                                    | not enforced — a suite missing from CI passes locally and never runs on a tag        |
| The state-file read API siblings grep for (path `.repete/loop.local.md`, key `active`, value form `true` in the FIRST frontmatter block)             | Nothing in-tree — but cc-reload's `repete_active()` greps it to stand down, so a rename/move/value-shape change breaks a sibling silently. Update core-load-bearing item 6 and notify the sibling repo. Do not "fix" the divergence by loosening our own reads — their bare grep matching body prose is their bug                                                                                            | test: `#27` contract blocks                                                              |
| The scan jq program (`TURN_SCAN_JQ`)                                                                                                                | Nothing — it is defined ONCE and reused by all three paths (fast path, mktemp-failure fallback, growth loop). It was three verbatim copies; if you ever re-inline it, the paths can silently disagree                                                                                                                                                                                                               | tests: window-scan blocks + the `#18` blocks                                         |
| Window sizing (`WINDOW_LINES`, `WINDOW_GROWTH`)                                                                                                     | Nothing mechanical — but the initial size must stay comfortably above the documented 500-sidechain hazard, and the growth predicate must stay "contains a turn boundary" (see landmine)                                                                                                                                                                                                                             | tests: window-scan blocks                                                            |
| Transcript scan shape (`$turn_start`, text-bearing pick)                                                                                            | The #18 test block — both directions (sentinel behind a tool tail IS seen; a spent sentinel from a previous turn is NOT) AND every observed user-row shape that decides the boundary: bare `tool_result`, plain string, `text`, `image+text`, `tool_result`+text mixed, sidechain                                                                                                                                   | tests: `#18` blocks                                                                  |
| `.repete/.warned-nojq` marker path                                                                                                                  | Hook no-jq branch + the warning text that names it for deletion                                                                                                                                                                                                                                                                                                                                                     | tests: `#7` blocks                                                                   |
| Hook behavior described in README/commands/skills                                                                                                   | The prose in all three                                                                                                                                                                                                                                                                                                                                                                                              | not enforced — grep manually                                                         |
| Behavior a `docs/spec/*` file describes (`stale-detection.md` for `stale_count`/`stale_limit`, `gauntlet-mode.md` for `gauntlet`/`reference`/`bar`) | Add a `> Refined in vX.Y.Z` note to the spec section the change supersedes, pointing at the live logic — do NOT rewrite the record                                                                                                                                                                                                                                                                                  | not enforced — grep manually; the spec is a design record, the hook is authoritative |
| `tests/run-all.sh` checks                                                                                                                           | `.github/workflows/ci.yml` AND `.github/workflows/release.yml` (three sites, all by hand)                                                                                                                                                                                                                                                                                                                           | not enforced — keep in sync by hand                                                  |
| Default re-inject content (protocol wording, rules, assembly)                                                                                       | `tests/golden-default-reinject.sha` — regenerate with `bash tests/regen-golden.sh` (its fixture mirrors the golden test block; keep both in sync)                                                                                                                                                                                                                                                                   | test: golden block                                                                   |
| `plugin.json` version                                                                                                                               | Newest `## [x.y.z]` CHANGELOG heading + README version line + the release tag                                                                                                                                                                                                                                                                                                                                       | `scripts/release-gate.mjs` at tag push; `tests/test-release-gate.mjs`                |
| `.claude-plugin/marketplace.json`                                                                                                                   | jq validity check in run-all.sh + ci.yml + release.yml (it serves `/plugin marketplace add` from repo HEAD)                                                                                                                                                                                                                                                                                                         | run-all/ci jq step                                                                   |

## Landmines (non-obvious decisions that look like mistakes)

- **`set -uo pipefail` without `-e` is deliberate.** Much of the hook treats non-zero
  as data (grep misses, perl sentinel probes). Adding `-e` will break it subtly.
- **`STALE_NOTE` is initialized OUTSIDE the `summarizing` guard.** The summarizing path
  skips the whole sentinel block but still flows through the re-inject assembly, which
  reads `STALE_NOTE` — under `set -u` an init placed inside the guard crashes every
  summarizing-path Stop. Same trap applies to any future variable set inside a guarded
  block but consumed after it.
- **`fm()` reads the FIRST occurrence of a key; the test `scaffold()` only APPENDS.** A
  default value seeded in the scaffold plus a `scaffold 'key: override'` extra yields two
  keys and the hook silently reads the default — the exact trap the backstop tests'
  comment warns about, rediscovered for `gauntlet`. Seed nothing you intend to override;
  use `setstate` to mutate.
- **`GAUNTLET_FALLBACK` mirrors `PROTO_FALLBACK`** (and `critique.md`'s pointer is
  first-line-only): the loop must never silently lose its working rules when the template
  is unreadable, and the critique pointer stays metadata — injecting critique bodies every
  iteration would re-create the context rot the catalog rules fight. The pointer is
  appended AFTER the template/fallback resolution, so BOTH paths carry it when
  critique.md exists (verified by review).
- **`set_fm` updates only the first frontmatter block and appends missing keys before
  the closing `---`** (C1/C2/C3 in the comments). Since v0.2.1 the value travels via
  `ENVIRON["REPETE_FM_VAL"]`, not `awk -v` — `-v` runs the value through awk's escape
  processing, so a literal `\` in a value was eaten (issue #10). Keep it that way if
  free-text values ever land in frontmatter. Its `END` block is the fenceless-file
  path (issue #11): a frontmatter that was opened and never closed used to make the
  C3 append a silent no-op, so the backstop cap never persisted and the hook re-warned
  every Stop; now the key is appended at EOF and the closing `---` is written after it.
  EOF is the only possible landing spot — without a closing fence, `f==1` covers the
  whole remainder and no rule distinguishes a trailing key from body prose. So on a
  fenceless file the body ends up _above_ the repaired fence: byte-intact (locked by
  test) but outside `PAYLOAD_BODY`, which is where it already was, since that
  extraction reads after the SECOND fence and a fenceless file never had one. Both the
  pre- and post-v0.2.1 hooks inject zero body lines there. Do not "improve" this by
  guessing where the split belongs: a heuristic that promotes body prose into live
  frontmatter is the strictly worse failure.
- **`hooks/promote.sh` fails LOUD — the opposite of the hook's one rule, deliberately.**
  It is human-gated (invoked once from `/repete-continue` after the user approved the
  payload), not an unattended Stop path, so a silent partial write IS the defect issue #8
  exists to fix: non-zero exit plus a message naming what could not be written. Do not
  harmonize it with `set_fm`'s fail-open direction. It mirrors `set_fm`'s C1/C2/C3 and
  #11 guarantees, generalized to six keys in one awk pass; it does NOT touch the body —
  the payload replace stays a Write the calling command performs. It also de-BOMs the
  state file before reading (v0.2.3): a BOM glues to the opening `---`, so the phase read
  returns empty AND the writer's `f==1` block never opens — six keys would land in the
  wrong scope. Same C1 trap the hook's on-disk de-BOM fixed in v0.2.2. If the BOM cannot
  be stripped (unwritable, no perl) it REFUSES and says so, rather than writing into a
  file it knows is mis-scoped.
- **`od -An -tx1` pads with variable whitespace** — two spaces between bytes on BSD od,
  plus a leading indent. A `grep -q 'ef bb bf'` against its output silently never matches,
  turning a byte-signature guard into a no-op that looks correct in review. Squeeze with
  `tr -s '[:space:]' ' '` and match against `" ef bb bf "*`. This was live in promote.sh's
  BOM guard for one commit and only surfaced because the tests were run red-first.
- **Iteration semantics:** `iteration` counts completed work turns; the cap check is
  `>=` _before_ the bump, so `max_iterations: 3` = exactly 3 work turns. The handoff
  (`summarizing`) turn is free — no bump.
- **`summarizing` owns its Stop.** Sentinels and the iteration cap are suppressed while
  in it, and the stranded-recovery path re-applies the cap on exit. This is what keeps
  the /clear flow undivertable; don't "simplify" the suppression away.
- **A checkpoint beats a done in the same message (I2)** — the human-gated path is the
  safe one. Autonomous mode instead forces `HAS_CHECKPOINT=0` so only done/budgets stop it.
- **The autonomous backstop** (both budgets 0 → stamp `max_iterations: 25`) exists so a
  buggy mission goal can never block Stop forever. It must persist to state (C3) or it
  warns every iteration. Since the 2026-08 audit it applies to GATED loops too — a gated
  loop whose agent never checkpoints has no other mechanical stop (51 consecutive
  iterations reproduced). Any active loop with both budgets 0 gets the cap.
- **Gauntlet rules require `reference:` AND `bar:` non-empty** (audit F10): injecting
  builder/critic rules with nothing to reference is iteration-burning theater. The hook
  gates on both keys; the flag alone is not enough.
- **Constitution/handoff "emptiness" tests strip scaffolding literally** — HTML
  comments, the template's exact headings, whole-line `<placeholders>`. Stripping any
  `#`-leading line instead would misclassify real content like "# TODO finish parser".
- **Body extraction prints-before-increment (I1)** so a `---` horizontal rule inside
  the loop body is preserved, not swallowed.
- **The window grows on "contains a turn boundary", NOT on "found assistant text"**
  (issue #9). The issue's own acceptance text proposed the text predicate; it is wrong two
  ways. A tool-only turn legitimately has no assistant text, so that predicate forces a
  full read every Stop — safe but pointless. Far worse: a window can contain assistant
  text while missing the boundary that bounds it, and `$turn_start` then falls back to
  `-1`, meaning "scan this whole window" — so the scan reads across into the PREVIOUS turn
  and can re-fire a spent sentinel (re-pausing at an already-approved checkpoint). That is
  fail-closed, reached from a different door than the bug #9 set out to avoid. The
  boundary predicate is safe because the window is always a `tail -n` SUFFIX: a suffix
  containing any boundary necessarily contains the LAST one in the file, so the turn slice
  — and therefore `.l`/`.a` — is identical to a full read's. Terminal condition is `tail`
  returning fewer lines than requested (the window IS the file), which also covers the
  legitimate no-boundary-anywhere case where `-1` is correct.
- **Count window lines with `grep -c ''`, NEVER `wc -l`** (issue #9 review, reproduced).
  `wc -l` counts NEWLINES. A transcript whose last line has no trailing newline — the
  routine shape of a file being appended to right now, read between a line's bytes and
  its newline — makes `tail -n 2000` return 2000 whole lines but only 1999 newlines. The
  growth loop's "fewer lines than requested ⇒ the window IS the file" test then fires one
  line early and stops growing with the turn boundary still outside the window: a real
  `<repete-done>` goes invisible and the loop re-injects past its own exit condition.
  Fail-closed, the forbidden direction, and the full suite was green while it was live.
  Both counters (fast-path `TOTAL_LINES`, loop `WINDOW_ROWS`) use `grep -c ''` so they
  cannot drift apart again. Measured on 37.9MB/100k lines: `grep -c` 0.00s, `wc -l`
  0.04s, `awk END{NR}` 0.76s — the safe counter is also the fastest.
- **Test the window's MECHANISM, not just its answer.** Every window assertion that checks
  `status`/`decision` passes identically whether the early exit fired or the loop fell
  through to a full read — so a regression that silently disables the early exit (renamed
  `.found`, changed jq output shape) degrades every Stop back to a full read with the suite
  green. Proven: mutating `FOUND_BOUNDARY` to a constant `false` left all 12 window
  assertions passing. The lock is an INVOCATION COUNT, not wall-clock — a `jq` shim on
  PATH logs whether jq was ever handed the transcript path itself; early exit means it only
  ever sees the tmpfile window. Immune to machine speed, so it cannot flake. Use that
  technique for any future "did the fast path actually fire" question.
  KNOWN UNTESTED: whether `PARSED_LINES` accumulates across rounds. Mutating it to
  `PARSED_LINES=$WINDOW_ROWS` (last round only) changes no observable behavior below
  ~576,000 transcript lines — the round count is identical, so the smallest fixture that
  could catch it is ~50MB. Verified by simulating the loop over 9k..5M lines. Deliberately
  not tested; if you touch the growth arithmetic, re-run that simulation.
- **Validate every count with `^[0-9]+$`, not `-z`.** `[[ "$x" -le N ]]` on a non-numeric
  value is a bash RUNTIME error, and under `set -u` that aborts the hook mid-run with no
  JSON emitted at all. `grep -c` yields digits or empty today, so the regex guards a
  contract rather than a live bug — but the block's whole fail-open story rested on that
  implicit contract, and a busybox or minimal-container `grep` need not honour it. An
  invalid count routes to the direct read (correct and cheap), never to a guess.
- **Every external command the window scan depends on must fall back to the full read.**
  The pre-window hook needed only `jq`; the windowed one also needs `tail`, `grep -c` and
  `mktemp`. Each is a NEW way to lose a sentinel the old code saw — `tail` dying (ENOSPC
  writing the tmpfile, a broken PATH, a mid-loop permission change) leaves an empty window,
  the scan finds nothing, and a real `<repete-done>` goes invisible while the loop
  re-injects past its own exit condition. Reproduced with a `tail` shim exiting 1: the old
  hook tore down, the windowed hook re-injected. Every such failure now reads the whole
  file instead — an optimization may never be worse than the thing it replaced.
  THREE instances of this one class have now shipped and been caught in review: the
  `wc -l` newline undercount, the unchecked `tail`, and a failing `grep -c` on the window
  tmpfile being read as "tail returned short, so this window IS the file" — that last one
  accepted an undersized boundary-less window as final and hid a real `<repete-done>`
  outside it (reproduced with a grep shim failing only on the tmpfile). A count failing is
  NOT the same fact as a short window; do not collapse the two.
- **Bound CUMULATIVE window work, not the last doubling.** R growth rounds parse the SUM
  of the windows, so the waste is GEOMETRIC. The first attempt bounded only the final
  doubling (`NEXT_WINDOW >= TOTAL_LINES/2`) and a second review refuted it: on a 256k-line
  file the loop still burned 2000+16000+128000 wasted lines before the full read, +78%
  wall-clock — the same magnitude as the regression the bound was meant to remove. The
  live rule tracks `PARSED_LINES` and stops once parsed-so-far plus the next window would
  exceed a QUARTER of the file (256k deep-boundary: +78% → +9%). That alone is NOT enough:
  a file just over one window pays a whole wasted window plus the full read — 4001 lines
  parsed for a 2001-line question, 2.0x, worse than never windowing. Review caught the
  "~1.25x regardless of depth" claim being false there — the SECOND unqualified worst-case
  bound to ship in this block. Fixed in the code, not the wording: the direct-read guard
  is `4 * WINDOW_LINES`, below which windowing cannot pay for itself (the first window is
  already ≥25% of the file). With both rules the 1.25x bound holds at EVERY size —
  simulated over 2001..400000 lines, peak exactly 1.25x near 72000. The case the window
  exists for — a boundary a few thousand lines back in a 100k-line transcript — stops at
  the first window and never reaches this bound.
  **A wall-clock assertion in CI is a flake generator, so the test pins the ANSWER on a
  deep-boundary transcript, not the timing.** The perf claim is measured by hand; if you
  change the bound, re-measure rather than trusting the suite.
- **Sentinel extraction reads the last TEXT-BEARING assistant entry of the current
  turn, not the last entry** (issue #18). The harness appends an entry per content
  block and per bookkeeping record, so a turn that claims done and then makes a tool
  call ends with a `tool_use`-only entry whose text is `""` — the old `| last` read
  that, blanking the claim: no teardown, and the mismatch branch never ran either, so
  the loop re-injected forever with zero feedback to agent or stale detector. The scan
  is bounded to the current turn (everything after the last main-thread `user` entry
  that carries a NON-`tool_result` block — tool results are `role:user` too and must
  not count as a boundary); without that bound a text-less turn would re-fire a spent
  sentinel and re-pause at an already-approved checkpoint. Both directions are tested.
  The boundary test is "has a non-tool_result block", NOT "has no tool_result": the
  observed user-row shapes are `tool_result` / `string` / `text` / `image+text`
  (18801/1939/207/23 across 75 real transcripts), and a row mixing a tool_result with
  real human text is a new instruction that must open a turn. `.text | strings` drops a
  non-string `.text` rather than letting `join()` raise — **a jq runtime error aborts
  the whole program**, so one malformed block would blank the entire scan and blind
  sentinel detection (fail-closed). The old `| last` touched exactly one entry; this
  program walks many, so it has strictly more rows to trip over.
- **The no-jq warning is hand-built JSON** (issue #7) — `emit()` needs jq, so that
  branch `printf`s a fixed literal with no interpolation (hence no escaping concerns)
  and marks `.repete/.warned-nojq` so it fires once per `.repete/` — nothing clears that
  marker (`/repete-cancel` leaves state by design, `/repete` archives rather than deletes),
  so it stays quiet across later loops in the project until the user deletes it; the
  message names the path for exactly that reason. It is gated on `active: true` so
  a finished loop stays quiet, and every branch still exits 0. The gate is an inline
  `awk` scoped to the first frontmatter block, not a bare `grep`: `fm()` is defined
  further down and belongs to the jq-era helpers, but a plain grep also matches a BODY
  line like `active: true` (loop prose quoting the schema) and warned about finished
  loops — the same C1 trap `set_fm` guards against.
- **Session isolation stamps on first sight** because commands can't reliably know the
  session id at setup. Every resume path in `/repete-continue` blanks `session_id` —
  a stale id makes the hook silently ignore the resumed session (looks like a dead loop).
- **Lesson catalog is metadata-only by design.** Injecting card bodies every iteration
  is the exact context-rot source the design fights. Keep it one line per card.

## How to change the hook safely

1. Write the failing `ck` test first in `tests/test-hooks.sh` (copy an existing block;
   `scaffold`/`setstate`/`mktx`/`run` are the whole harness — note `scaffold` seeds a
   lesson card, remove it if your fixture ranks cards).
2. Make the smallest change that passes; state the failure direction in a comment.
3. `bash tests/run-all.sh` — all suites plus shellcheck must be green. If you changed
   the default re-inject deliberately, `bash tests/regen-golden.sh` and commit the new
   sha WITH the change.
4. Grep commands/README/skills **and `docs/spec/`** for descriptions of the behavior you
   changed. The spec files are approved-design records, not prompt-code — they do not
   execute, so the failure mode is a maintainer reading superseded behavior as current
   while chasing a bug (that is how the F03 stale-reset drift survived until a review
   round caught it). Append a `> Refined in vX.Y.Z` note naming the live logic; never
   rewrite the record to match the code.
5. Bump `version` in `.claude-plugin/plugin.json`, the README's version line, AND add
   the matching `## [x.y.z]` entry newest in CHANGELOG.md — the release is tag-driven
   (`.github/workflows/release.yml` + `scripts/release-gate.mjs`) and the gate fails any
   tag where the trio disagrees; the CHANGELOG section becomes the release body.

## Residual risks / backlog (prioritized, with context)

1. **~~Checkpoint promotion is prompt-code~~ — SHIPPED v0.2.3 (issue #8).** `hooks/promote.sh`
   now writes all six keys in one atomic awk pass and `/repete-continue` step 4 shells out
   to it. Residue: the other three resume branches (`paused-context`, `paused-stale`,
   `paused-max`) still hand-edit `status` → running and blank `session_id` — a strict
   subset of what promote.sh writes. A `--resume-only` flag would fold them in; not done,
   because those branches also require a human judgment step promote.sh cannot encode.
2. **Transcript parse trusts `.message.role` / `.type` shape.** v0.2.1 leans on it
   harder: the turn boundary is "last main-thread `role:user` entry that is not purely
   `tool_result` blocks". If the transcript format changes upstream, the boundary
   degrades to "scan everything" (the pre-v0.2.1 scope, fail-open) — but watch Claude
   Code release notes, and re-check `hooks/stop-hook.sh`'s `$turn_start` if the shape
   of user/tool_result entries moves.
3. **`context_budget_lines` counts transcript lines, not tokens** (issue #15) — documented as a
   loose proxy. If a tokens-ish signal becomes available in hook input, prefer it.
4. **v2/v3 roadmap** (README, issues #13/#14): phased missions; global lesson store with
   recurrence-gated promotion. The state model was designed to extend to both.
5. **~~Per-Stop transcript cost is O(whole transcript)~~ — SHIPPED (issue #9).** The scan
   now grows a `tail -n` window until it contains a turn boundary; see the three window
   landmines (boundary predicate, `grep -c` not `wc -l`, cumulative growth bound).
   Measured end-to-end, old vs new, same machine: 33.6MB/13.7k lines 0.50s → 0.21s;
   37.9MB/100k lines 0.85s → 0.14s; 27.1MB/1.7k fat lines 0.39s → 0.40s (fits the initial
   window, takes the direct-read fast path, pays one extra line count — accepted); 40k
   deep-boundary 0.39s → 0.43s; 256k deep-boundary 2.16s → 2.33s. The issue's cited ~2.8s
   never reproduced here; RSS did. Residue: the `fm()` fork count (~60/Stop) is real but
   millisecond-scale — batch opportunistically, never urgently.
6. **Sentinel visibility across a multi-entry turn — open design question** (issue #24;
   2026-08-31 audit F03 residue): a done-claim in an EARLIER text entry of the turn is neutral
   since v0.2.2 (no teardown, no count, no longer a counter reset), but it is still
   invisible — a correct claim followed by a wrap-up sentence burns iterations to the
   budget with zero feedback. The full fix is joining ALL the turn's text entries for
   sentinel detection, but that reverses the test-locked v0.2.1 "later text entry wins"
   decision (a claim the agent verbally walked back would then tear the loop down —
   the expensive failure direction). Decide only with real-transcript evidence of how
   often each shape occurs; the `#18` test block is where both directions are pinned.
7. **Audit cuts still open** (from the 2026-08-16 max audit, verified but unfixed):
   the "keep/!update" garble lineage in repete-continue step 4 (fixed wording, watch
   regressions). The rest of that list shipped in v0.2.1: `set_fm` ENVIRON (#10),
   fenceless-file append (#11), bare `paused` removal (#12), no-jq warn-once (#7),
   the three missing tests (#16), and the `jq -e` assertion convention (#17 —
   documented in the test header, applied to new assertions, migrated opportunistically).
8. **~~A failed `set_fm` write announces success it never persisted~~ — SHIPPED v0.2.3
   (issue #21).** `set_fm_or_warn` guards every write whose message promises persistence.
   RESIDUE, still open: `set_fm` orphans its `.tmp.$$` when `mv` fails — no `|| rm -f`,
   unlike the de-BOM block right above it. Cosmetic next to the announce bug, but it
   litters `.repete/` on a full disk, which is exactly when the user is already in trouble.
9. **~~Release notes truncate at a `[LABEL]: text` body line~~ — SHIPPED v0.2.3 (issue #22).**
   The stop pattern now requires the URL shape.
10. **~~`docs/spec/*` is outside the couplings table~~ — SHIPPED v0.2.3 (issue #23).**
    Couplings row added, safe-change step 4 names it, and each spec file declares itself a
    design record that may lag the code.
