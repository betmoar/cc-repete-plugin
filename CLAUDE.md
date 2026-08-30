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
- **A sentinel the agent really emitted must be SEEN** (v0.2.1, issue #18). Missing one
  looks fail-open (the loop keeps going) but is a trap in practice: a correct done-claim
  that the hook cannot see never tears down, never counts as stale, and never reaches the
  human — the loop spins to its budget with the exit condition already satisfied. So
  sentinel extraction reads the last text-bearing entry of the turn, not the last entry.

If you add a check, decide its failure direction first and write it in a comment.

## Couplings — if you touch X, update Y

| You changed | You must also update | Enforced by |
| --- | --- | --- |
| `templates/handoff.md` section headings | Hook pass-1 re-inject brief AND pass-2 scaffolding-strip pattern | test: "Coupling lock: templates/handoff.md headings" |
| `templates/protocol.md` placeholders | Hook substitution + `PROTO_FALLBACK` | test: "Protocol placeholders" |
| `loop.local.md` frontmatter keys | Hook `fm` reads, `commands/repete.md` scaffold, `/repete-status`, test `scaffold()` | tests use the schema throughout |
| Status values | Hook early-exit case, `/repete-continue` branches, `/repete-status` map, statusline `case` (renders `·ck/·ctx/·max/·stale` markers — a new status silently renders as healthy) | tests: paused/terminal blocks |
| `stale_count`/`stale_limit` keys | Hook `fm` reads + mismatch branch, `templates/loop.local.md`, `/repete` scaffold prose, `/repete-status` budgets line, `/repete-continue` paused-stale branch | tests: stale blocks |
| `gauntlet`/`reference`/`bar` keys | Hook `fm` read + gauntlet injection block, `templates/loop.local.md`, `/repete` optional-features, `/repete-status` gauntlet section, tests scaffold comment | tests: gauntlet blocks |
| `templates/gauntlet.md` content | Hook injection + `GAUNTLET_FALLBACK` + the test coupling-lock phrases (`parts.md`, `critic`, `final integration`) | test: "Coupling lock: templates/gauntlet.md" |
| Sentinel strings | Hook + README always; `<repete-done>` also protocol + running skill + /repete; `<repete-checkpoint>` also running skill + /repete-continue (NOT protocol.md — the frozen core stays quiet; the rule rides RULES_EXTRA) | tests: doc-lock block |
| `templates/lesson-card.md` frontmatter (incl. inline `#` comments) | `card_field`'s comment-stripping | test: catalog block |
| Transcript scan shape (`$turn_start`, text-bearing pick) | The #18 test block — both directions (sentinel behind a tool tail IS seen; a spent sentinel from a previous turn is NOT) AND every observed user-row shape that decides the boundary: bare `tool_result`, plain string, `text`, `image+text`, `tool_result`+text mixed, sidechain | tests: `#18` blocks |
| `.repete/.warned-nojq` marker path | Hook no-jq branch + the warning text that names it for deletion | tests: `#7` blocks |
| Hook behavior described in README/commands/skills | The prose in all three | not enforced — grep manually |
| `tests/run-all.sh` checks | `.github/workflows/ci.yml` (and vice versa) | not enforced — keep in sync by hand |

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
  fenceless file the body ends up *above* the repaired fence: byte-intact (locked by
  test) but outside `PAYLOAD_BODY`, which is where it already was, since that
  extraction reads after the SECOND fence and a fenceless file never had one. Both the
  pre- and post-v0.2.1 hooks inject zero body lines there. Do not "improve" this by
  guessing where the split belongs: a heuristic that promotes body prose into live
  frontmatter is the strictly worse failure.
- **Iteration semantics:** `iteration` counts completed work turns; the cap check is
  `>=` *before* the bump, so `max_iterations: 3` = exactly 3 work turns. The handoff
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
3. `bash tests/run-all.sh` — all suites plus shellcheck must be green.
4. Grep commands/README/skills for descriptions of the behavior you changed.
5. Bump `version` in `.claude-plugin/plugin.json` and the README's version line.

## Residual risks / backlog (prioritized, with context)

1. **`/repete-continue`'s checkpoint promotion is prompt-code** — the agent hand-edits
   frontmatter (phase +1, iteration reset, blank session). A `hooks/promote.sh` the
   command shells out to would make it mechanical and testable. Medium effort.
2. **Transcript parse trusts `.message.role` / `.type` shape.** v0.2.1 leans on it
   harder: the turn boundary is "last main-thread `role:user` entry that is not purely
   `tool_result` blocks". If the transcript format changes upstream, the boundary
   degrades to "scan everything" (the pre-v0.2.1 scope, fail-open) — but watch Claude
   Code release notes, and re-check `hooks/stop-hook.sh`'s `$turn_start` if the shape
   of user/tool_result entries moves.
3. **`context_budget_lines` counts transcript lines, not tokens** — documented as a
   loose proxy. If a tokens-ish signal becomes available in hook input, prefer it.
4. **v2/v3 roadmap** (README): phased missions; global lesson store with
   recurrence-gated promotion. The state model was designed to extend to both.
5. **Per-Stop transcript cost is O(whole transcript)** (audit F13, measured 342MB RSS /
   ~2.8s per Stop on a 32MB transcript, re-paid every iteration). A naive tail-bound is
   UNSAFE (500 trailing sidechain lines can hide the last main-thread sentinel —
   fail-closed); the fix needs a grow-the-window scan that falls back to a full read
   when the window comes up sentinel-blind. Own engagement; don't bolt onto another fix.
   The fm() fork count (~60/Stop) is real but millisecond-scale — batch opportunistically,
   never urgently. **Note:** v0.2.1's turn-bounded scan is still a full read — it
   changed WHICH entry is chosen, not how much is parsed. The grow-the-window fix must
   preserve the turn boundary, so its window has to reach back past the last user entry,
   not just past the last assistant text.
6. **Audit cuts still open** (from the 2026-08-16 max audit, verified but unfixed):
   the "keep/!update" garble lineage in repete-continue step 4 (fixed wording, watch
   regressions). The rest of that list shipped in v0.2.1: `set_fm` ENVIRON (#10),
   fenceless-file append (#11), bare `paused` removal (#12), no-jq warn-once (#7),
   the three missing tests (#16), and the `jq -e` assertion convention (#17 —
   documented in the test header, applied to new assertions, migrated opportunistically).

## Operator

@OPERATOR.md — it is this session's operating charter. Local and gitignored: in a fresh
clone this import silently no-ops — run `/cc-operator:start` to materialize the charter.
