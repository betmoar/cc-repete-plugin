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
   statuses exit → session isolation (stamp on first sight) → autonomous no-budget
   backstop → read last main-thread assistant message → sentinel handling (suppressed
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
   Adding a status means updating: the hook's early-exit case, `/repete-status`'s "what to do
   next" map, and `/repete-continue`'s branch list.

## Failure philosophy (the one rule)

**The hook may only fail OPEN.** Every uncertain situation must resolve toward "let the
Stop through" or "keep looping within budgets" — never toward trapping the user or
tearing the loop down on a false positive. Concrete embodiments:

- No `jq` → exit 0 silently (can't steer, so don't intervene).
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

If you add a check, decide its failure direction first and write it in a comment.

## Couplings — if you touch X, update Y

| You changed | You must also update | Enforced by |
| --- | --- | --- |
| `templates/handoff.md` section headings | Hook pass-1 re-inject brief AND pass-2 scaffolding-strip pattern | test: "Coupling lock: templates/handoff.md headings" |
| `templates/protocol.md` placeholders | Hook substitution + `PROTO_FALLBACK` | test: "Protocol placeholders" |
| `loop.local.md` frontmatter keys | Hook `fm` reads, `commands/repete.md` scaffold, `/repete-status`, test `scaffold()` | tests use the schema throughout |
| Status values | Hook early-exit case, `/repete-continue` branches, `/repete-status` map | tests: paused/terminal blocks |
| `stale_count`/`stale_limit` keys | Hook `fm` reads + mismatch branch, `templates/loop.local.md`, `/repete` scaffold prose, `/repete-status` budgets line, `/repete-continue` paused-stale branch | tests: stale blocks |
| `gauntlet`/`reference`/`bar` keys | Hook `fm` read + gauntlet injection block, `templates/loop.local.md`, `/repete` optional-features, `/repete-status` gauntlet section, tests scaffold comment | tests: gauntlet blocks |
| `templates/gauntlet.md` content | Hook injection + `GAUNTLET_FALLBACK` + the test coupling-lock phrases (`parts.md`, `critic`, `final integration`) | test: "Coupling lock: templates/gauntlet.md" |
| Sentinel strings | Hook, protocol, all commands, README, both skills | tests grep re-inject for both |
| `templates/lesson-card.md` frontmatter (incl. inline `#` comments) | `card_field`'s comment-stripping | test: catalog block |
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
  iteration would re-create the context rot the catalog rules fight. The critique pointer
  is appended to the TEMPLATE text, so the fallback lacks it — acceptable: the fallback's
  job is round discipline, not verdict recall.
- **`set_fm` updates only the first frontmatter block and appends missing keys before
  the closing `---`** (C1/C2/C3 in the comments). It uses `awk -v`, which treats
  backslashes in values as escapes — fine for everything written today (statuses,
  numbers, UUID session ids); if a value could ever carry `\`, switch to `ENVIRON`.
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

1. **No-jq degradation is silent.** The hook exits 0 without telling the user their
   loop is inert. It cannot emit hook JSON without jq, but it *could* `printf` a
   hand-built static JSON warning once (needs a "warned already" marker file to avoid
   spamming every Stop). Low effort, real UX win.
2. **`/repete-continue`'s checkpoint promotion is prompt-code** — the agent hand-edits
   frontmatter (phase +1, iteration reset, blank session). A `hooks/promote.sh` the
   command shells out to would make it mechanical and testable. Medium effort.
3. **Transcript parse trusts `.message.role` shape** beyond the guards added; if the
   transcript format changes upstream, sentinel detection degrades open (loop keeps
   iterating to budget). Watch Claude Code release notes.
4. **`context_budget_lines` counts transcript lines, not tokens** — documented as a
   loose proxy. If a tokens-ish signal becomes available in hook input, prefer it.
5. **v2/v3 roadmap** (README): phased missions; global lesson store with
   recurrence-gated promotion. The state model was designed to extend to both.
6. **Per-Stop transcript cost is O(whole transcript)** (audit F13, measured 342MB RSS /
   ~2.8s per Stop on a 32MB transcript, re-paid every iteration). A naive tail-bound is
   UNSAFE (500 trailing sidechain lines can hide the last main-thread sentinel —
   fail-closed); the fix needs a grow-the-window scan that falls back to a full read
   when the window comes up sentinel-blind. Own engagement; don't bolt onto another fix.
   The fm() fork count (~60/Stop) is real but millisecond-scale — batch opportunistically,
   never urgently.
7. **Audit cuts still open** (from the 2026-08-16 max audit, verified but unfixed):
   `set_fm`'s awk -v backslash mangling (UUID-safe today — switch to ENVIRON if free-text
   values ever land in frontmatter); set_fm C3 append no-ops on a state file missing its
   closing `---` (backstop re-warns every Stop); bare `paused` status vestige (no writer,
   no resume branch — remove or wire); gauntlet `[[ -s critique.md ]]` true for a
   directory (empty-verdict pointer — guard with `-f` if it ever bites); the
   "keep/!update" garble lineage in repete-continue step 4 (fixed wording, watch
   regressions); missing tests for no-jq exit-0, stranded-summarizing cap re-application,
   transition.md content; ck `jq | grep -q` SIGPIPE false-FAIL on >64KB payloads
   (dormant under current fixtures — switch to `jq -e` predicates when touched).

## Operator

@OPERATOR.md — it is this session's operating charter.
