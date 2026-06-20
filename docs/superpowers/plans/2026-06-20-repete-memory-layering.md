# repete v2 — Memory Layering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace repete's single hardcoded re-inject block with a four-layer memory model (evolving brief + lessons catalog + user constitution + engine protocol) so context stays clean across loop iterations without changing the control flow.

**Architecture:** The Stop hook (`hooks/stop-hook.sh`) stays the loop spine — single session, `decision:block`+`reason` re-inject. This plan touches *only what goes into the `reason` string*, never the three-way decision or the safety yields. The hardcoded RULES heredoc becomes an assembled string from four sources, ordered frozen-layers-last. Lessons are delivered as a metadata-only catalog the hook builds fresh each Stop; card bodies enter context only via the agent's on-demand `Read`. All new file reads are fail-functional (missing → degrade quality, never trap the loop).

**Tech Stack:** Bash 5 (hook engine), `jq` (transcript + decision JSON), `perl` (sentinel extraction), `awk` (frontmatter parsing), Markdown (commands, templates). Tests are a bash smoke harness that drives the real hook with synthetic state + transcript fixtures.

## Global Constraints

Copied verbatim from the spec (`docs/superpowers/specs/2026-06-20-repete-memory-layering-design.md`). Every task's requirements implicitly include these:

- **Hook spine only.** No external runner. The hook cannot clear context; mitigation is layering, not process restart.
- **The hook's three-way decision (done / checkpoint / continue) and both safety yields (max_iterations, context_budget) are UNCHANGED.** This plan modifies only the re-inject payload assembled in the autonomous-continue branch (`stop-hook.sh:129-152`).
- **The two sentinels and their semantics are UNCHANGED:** checkpoint-wins-over-done (line 87-88), exact-string `<repete-done>` match (line 91-99).
- **No card bodies in the re-inject, ever.** The lessons catalog is metadata-only by construction.
- **Fail-functional, not fail-silent.** Missing protocol template → inline fallback (loop continues with both sentinels alive). Missing/empty/comment-only constitution → skip silently. Missing lessons dir → empty catalog, no error. Matches the existing fail-open-on-missing-`jq` philosophy.
- **Frozen layers stay short and conflict-free.** Constitution + protocol combined should stay well under ~40 lines.
- **Re-inject assembly order is: (1) evolving brief, (2) lessons catalog, (3) user constitution, (4) engine protocol LAST.**
- **Catalog cap default = 8**, configurable via `lesson_catalog_cap` frontmatter (0 = uncapped).
- **Constraints are single-sourced to `.repete/constitution.md`;** `MISSION.md`'s Constraints section is a one-line pointer.
- Requires `jq` and `perl` (already hard deps of v1). Bash ≥ 4 for `${var//find/replace}` and `+=`.

---

## File Structure

**New files:**
- `templates/protocol.md` — the engine protocol, extracted from the v1 heredoc. Hook-versioned, shipped with the plugin, read at runtime with inline fallback. Carries `${PHASE}`/`${NEXT}` placeholders.
- `templates/constitution.md` — commented starter copied to `.repete/constitution.md` by the `/repete` scaffold. Documents hard-invariants vs evolving-brief.
- `tests/smoke/lib.sh` — shared harness helpers (state/transcript/lesson-card builders, hook runner, assert).
- `tests/smoke/control-flow.sh` — relocated `run.sh` (the 20 control-flow assertions).
- `tests/smoke/edge-cases.sh` — relocated `extra.sh` (sentinel edge cases).
- `tests/smoke/layers.sh` — NEW assertions for the four-layer assembly, catalog builder, fallback.
- `tests/smoke/all.sh` — runs all three suites, exits non-zero if any fail.

**Modified files:**
- `hooks/stop-hook.sh` — replace heredoc (137-146) with layered assembly; add `card_field`, `build_catalog`, constitution reader, protocol reader+fallback.
- `templates/loop.local.md` — add `lesson_catalog_cap: 8` frontmatter; redefine `## Known traps` section as a pointer (no card bodies).
- `templates/MISSION.md` — `## Constraints` section → one-line pointer to constitution.
- `commands/repete.md` — scaffold step writes `.repete/constitution.md` from template + `lesson_catalog_cap` frontmatter.
- `commands/repete-continue.md` — rehydrate path reads constitution; checkpoint step 3 stops copying card content.
- `commands/repete-status.md` — preview catalog as hook renders it; surface constitution presence/size.

**Testing reality (stated honestly):** The hook is bash; its tests are the smoke harness driving the real script — strong. Command/template files are *instructions to the agent*, not executable code; their "tests" are content assertions (grep for required/forbidden phrasing) — weaker. The integration proof for the command changes is the live 2-iteration round-trip in Task 6, which a human runs.

---

## Task 0: Relocate the smoke harness into the repo

The v1 harness lives in ephemeral `/tmp/repete-smoke/`. Move it into the repo so every later task's test cycle is durable and runnable verbatim. Fixtures still build under a `mktemp` root (outside the repo — the repo's own files contain literal sentinel strings, which would corrupt detection tests; and a `mktemp` root keeps `rm -rf` of subdirs clean past the global guard-rm hook).

**Files:**
- Create: `tests/smoke/lib.sh`
- Create: `tests/smoke/control-flow.sh`
- Create: `tests/smoke/edge-cases.sh`
- Create: `tests/smoke/all.sh`

**Interfaces:**
- Produces (sourced by every suite from `tests/smoke/lib.sh`):
  - `REPO_ROOT` — absolute repo root (computed from `BASH_SOURCE`).
  - `HOOK` — `$REPO_ROOT/hooks/stop-hook.sh`.
  - `ROOT` — a fresh `mktemp -d` fixtures root.
  - `mkstate DIR STATUS ACTIVE ITER MAX CTX GOAL SESSION` — writes `$DIR/.repete/loop.local.md` with that frontmatter + a fixed body (body includes a `---` rule line to test I1).
  - `mktrans FILE TEXT` — writes a 2-message JSONL whose last assistant message is `TEXT`.
  - `mkcard DIR SLUG TAGS SEVERITY HITS` — writes `$DIR/.repete/lessons/$SLUG.md` (card with the leading `<!-- -->` comment + frontmatter, per the real template shape).
  - `runhook DIR TRANSCRIPT SESSION` — runs the real hook with `CLAUDE_PROJECT_DIR=DIR`, sets `OUT` (stdout) and `RC`.
  - `getfm DIR KEY` — reads a frontmatter value from `$DIR/.repete/loop.local.md`.
  - `assert LABEL RC` — `RC==0` → PASS (increments `$PASS`), else FAIL (increments `$FAIL`, prints `$OUT`).
  - `summary` — prints `RESULT: $PASS passed, $FAIL failed` and returns non-zero if any failed.

- [ ] **Step 1: Write `tests/smoke/lib.sh`**

```bash
#!/usr/bin/env bash
# Shared helpers for the cc-repete smoke harness. Source this from each suite.
# Drives the REAL hooks/stop-hook.sh against synthetic state + transcripts in a
# mktemp fixtures root (outside the repo — the repo's own files contain literal
# sentinel strings that would corrupt detection tests).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/stop-hook.sh"
ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t repete-smoke)"
PASS=0; FAIL=0

mkstate() { # dir status active iter max ctx goal session
  local d="$1"; [[ "$d" == "$ROOT"/* ]] || { echo "refusing mkstate outside ROOT: $d" >&2; return 1; }
  rm -rf "$d"; mkdir -p "$d/.repete/lessons"
  cat > "$d/.repete/loop.local.md" <<EOF
---
active: $3
phase: 2
iteration: $4
session_id: $8
max_iterations: $5
context_budget_lines: $6
mission_goal: $7
lesson_catalog_cap: 8
status: $2
started_at: "x"
---
# Current loop payload
BODY-LINE-ONE
---
this is a horizontal rule inside body, must survive
final body line
EOF
}

mktrans() { # file text
  local f="$1"; shift
  : > "$f"
  printf '%s\n' "$(jq -nc --arg t "user msg" '{message:{role:"user",content:[{type:"text",text:$t}]}}')" >> "$f"
  printf '%s\n' "$(jq -nc --arg t "$1" '{message:{role:"assistant",content:[{type:"text",text:$t}]}}')" >> "$f"
}

mkcard() { # dir slug tags severity hits
  # Mirrors the REAL shipped lesson-card template: a leading <!-- --> comment
  # block before the frontmatter AND inline "# comment" prose on the tags /
  # severity / hits lines. This shape is what card_field must survive (B1) —
  # a clean-value fixture would false-green past the comment-strip bug.
  local d="$1" slug="$2" tags="$3" sev="$4" hits="$5"
  cat > "$d/.repete/lessons/$slug.md" <<EOF
<!--
  One lesson per file. Name NNN-short-slug.md.
-->
---
slug: $slug
tags: [$tags]   # used to decide which lessons to surface into a loop
severity: $sev       # how badly it bit
hits: $hits                              # increment each time this recurs
created: 2026-06-20
---

**Situation:** test card $slug
**Rule:** do the thing
EOF
}

runhook() { # projectdir transcriptpath sessionid
  local d="$1" t="$2" s="$3" input
  input="$(jq -nc --arg tp "$t" --arg sid "$s" '{transcript_path:$tp, session_id:$sid}')"
  OUT="$(CLAUDE_PROJECT_DIR="$d" printf '%s' "$input" | CLAUDE_PROJECT_DIR="$d" bash "$HOOK" 2>/dev/null)"
  RC=$?
}

getfm() { # dir key
  awk 'BEGIN{f=0}/^---[[:space:]]*$/{f++;next}f==1{print}f>=2{exit}' "$1/.repete/loop.local.md" \
    | grep "^$2:" | head -1 | sed "s/^$2:[[:space:]]*//"
}

assert() { # label rc
  if [[ "$2" -eq 0 ]]; then echo "  PASS: $1"; PASS=$((PASS+1));
  else echo "  FAIL: $1"; echo "        OUT=$OUT"; FAIL=$((FAIL+1)); fi
}

summary() {
  echo; echo "==== RESULT: $PASS passed, $FAIL failed ===="
  [[ "$FAIL" -eq 0 ]]
}
```

- [ ] **Step 2: Write `tests/smoke/control-flow.sh`** (the 20 v1 assertions, now sourcing `lib.sh`)

```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== T1: autonomous continue (block + re-inject, iteration increments) =="
D="$ROOT/t1"; mkstate "$D" running true 1 0 0 '"ship it"' '"sess-1"'
mktrans "$D/tr.jsonl" "did some work, not done yet"
runhook "$D" "$D/tr.jsonl" "sess-1"
echo "$OUT" | jq -e '.decision=="block"' >/dev/null 2>&1; assert "decision is block" $?
echo "$OUT" | jq -e '.reason | contains("BODY-LINE-ONE")' >/dev/null 2>&1; assert "reinject contains payload body" $?
echo "$OUT" | jq -e '.reason | contains("horizontal rule inside body")' >/dev/null 2>&1; assert "body --- rule survives (I1)" $?
[[ "$(getfm "$D" iteration)" == "2" ]]; assert "iteration incremented 1->2" $?

echo "== T2: checkpoint detected -> pause + transition.md written =="
D="$ROOT/t2"; mkstate "$D" running true 1 0 0 '"ship it"' '"sess-1"'
mktrans "$D/tr.jsonl" "goal met. <repete-checkpoint>NEXT PAYLOAD HERE</repete-checkpoint> stopping."
runhook "$D" "$D/tr.jsonl" "sess-1"
[[ "$(getfm "$D" status)" == "paused-checkpoint" ]]; assert "status -> paused-checkpoint" $?
grep -q "NEXT PAYLOAD HERE" "$D/.repete/transition.md"; assert "transition.md has payload" $?
echo "$OUT" | jq -e '.decision // "none" | . == "none"' >/dev/null 2>&1; assert "no block decision (stop allowed)" $?

echo "== T3: mission done -> teardown =="
D="$ROOT/t3"; mkstate "$D" running true 1 0 0 '"all tests green"' '"sess-1"'
mktrans "$D/tr.jsonl" "finished. <repete-done>all tests green</repete-done>"
runhook "$D" "$D/tr.jsonl" "sess-1"
[[ "$(getfm "$D" status)" == "done" ]]; assert "status -> done" $?
[[ "$(getfm "$D" active)" == "false" ]]; assert "active -> false" $?

echo "== T4: checkpoint WINS over done in same message (I2) =="
D="$ROOT/t4"; mkstate "$D" running true 1 0 0 '"all tests green"' '"sess-1"'
mktrans "$D/tr.jsonl" "<repete-done>all tests green</repete-done> but also <repete-checkpoint>more</repete-checkpoint>"
runhook "$D" "$D/tr.jsonl" "sess-1"
[[ "$(getfm "$D" status)" == "paused-checkpoint" ]]; assert "co-occurrence -> checkpoint, not done" $?

echo "== T5: done string MISMATCH does not tear down (false-exit guard) =="
D="$ROOT/t5"; mkstate "$D" running true 1 0 0 '"all tests green"' '"sess-1"'
mktrans "$D/tr.jsonl" "I think I am <repete-done>basically done maybe</repete-done>"
runhook "$D" "$D/tr.jsonl" "sess-1"
echo "$OUT" | jq -e '.decision=="block"' >/dev/null 2>&1; assert "mismatched done -> keeps looping (block)" $?
[[ "$(getfm "$D" active)" == "true" ]]; assert "still active" $?

echo "== T6: max_iterations safety yield =="
D="$ROOT/t6"; mkstate "$D" running true 3 3 0 '"x"' '"sess-1"'
mktrans "$D/tr.jsonl" "more work"
runhook "$D" "$D/tr.jsonl" "sess-1"
[[ "$(getfm "$D" status)" == "paused-max" ]]; assert "status -> paused-max at iter>=max" $?

echo "== T7: context budget safety yield =="
D="$ROOT/t7"; mkstate "$D" running true 1 0 5 '"x"' '"sess-1"'
: > "$D/tr.jsonl"; for i in 1 2 3 4 5 6 7 8; do printf '%s\n' "$(jq -nc --arg t "line $i" '{message:{role:"assistant",content:[{type:"text",text:$t}]}}')" >> "$D/tr.jsonl"; done
runhook "$D" "$D/tr.jsonl" "sess-1"
[[ "$(getfm "$D" status)" == "paused-context" ]]; assert "status -> paused-context over budget" $?

echo "== T8: session isolation — foreign session ignored =="
D="$ROOT/t8"; mkstate "$D" running true 1 0 0 '"x"' '"sess-OWNER"'
mktrans "$D/tr.jsonl" "work from a different session"
runhook "$D" "$D/tr.jsonl" "sess-INTRUDER"
[[ -z "$OUT" ]]; assert "foreign session -> no output (ignored)" $?
[[ "$(getfm "$D" iteration)" == "1" ]]; assert "foreign session did not advance iteration" $?

echo "== T9: session auto-stamp on first sight =="
D="$ROOT/t9"; mkstate "$D" running true 1 0 0 '"x"' '""'
mktrans "$D/tr.jsonl" "first turn"
runhook "$D" "$D/tr.jsonl" "sess-FRESH"
[[ "$(getfm "$D" session_id)" == '"sess-FRESH"' ]]; assert "empty session_id stamped to current" $?

echo "== T10: paused state -> hook is inert =="
D="$ROOT/t10"; mkstate "$D" paused-checkpoint true 1 0 0 '"x"' '"sess-1"'
mktrans "$D/tr.jsonl" "anything"
runhook "$D" "$D/tr.jsonl" "sess-1"
[[ -z "$OUT" ]]; assert "paused -> no intervention" $?

echo "== T11: no state file -> never interferes =="
D="$ROOT/t11"; rm -rf "$D"; mkdir -p "$D"
mktrans "$D/tr.jsonl" "normal stop"
runhook "$D" "$D/tr.jsonl" "sess-1"
[[ -z "$OUT" && "$RC" -eq 0 ]]; assert "no .repete -> clean exit 0, no output" $?

summary
```

- [ ] **Step 3: Write `tests/smoke/edge-cases.sh`** (relocated edge cases, sourcing `lib.sh`)

```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== E1: done matches despite whitespace/newline variation (norm) =="
D="$ROOT/e1"; mkstate "$D" running true 1 0 0 '"all   tests green"' '"s"'
mktrans "$D/tr.jsonl" "done: <repete-done>all
tests    green</repete-done>"
runhook "$D" "$D/tr.jsonl" "s"
[[ "$(getfm "$D" status)" == "done" ]]; assert "whitespace-variant done still matches" $?

echo "== E2: FALSE POSITIVE guard — bare opening tag in prose must NOT trigger =="
D="$ROOT/e2"; mkstate "$D" running true 1 0 0 '"all tests green"' '"s"'
mktrans "$D/tr.jsonl" "I will emit <repete-checkpoint> when this loop is done, but not yet."
runhook "$D" "$D/tr.jsonl" "s"
[[ "$(getfm "$D" status)" != "paused-checkpoint" ]]; assert "prose mention of opening tag does NOT pause" $?
echo "$OUT" | jq -e '.decision=="block"' >/dev/null 2>&1; assert "prose mention -> still autonomous continue" $?

echo "== E3: multi-line checkpoint payload captured whole =="
D="$ROOT/e3"; mkstate "$D" running true 1 0 0 '"g"' '"s"'
mktrans "$D/tr.jsonl" "ok <repete-checkpoint>line A
line B
line C</repete-checkpoint> stop"
runhook "$D" "$D/tr.jsonl" "s"
grep -q "line A" "$D/.repete/transition.md" && grep -q "line C" "$D/.repete/transition.md"; assert "multi-line checkpoint payload fully captured" $?

echo "== E4: missing transcript file -> autonomous continue, no crash =="
D="$ROOT/e4"; mkstate "$D" running true 1 0 0 '"g"' '"s"'
runhook "$D" "$D/nonexistent.jsonl" "s"
echo "$OUT" | jq -e '.decision=="block"' >/dev/null 2>&1; assert "missing transcript -> block (no crash)" $?

echo "== E5: stray closing tag ignored =="
D="$ROOT/e5"; mkstate "$D" running true 1 0 0 '"g"' '"s"'
mktrans "$D/tr.jsonl" "i typed a stray </repete-checkpoint> with no opener"
runhook "$D" "$D/tr.jsonl" "s"
[[ "$(getfm "$D" status)" != "paused-checkpoint" ]]; assert "stray closing tag ignored" $?

summary
```

- [ ] **Step 4: Write `tests/smoke/all.sh`**

```bash
#!/usr/bin/env bash
# Run every smoke suite; non-zero exit if any assertion failed.
set -uo pipefail
here="$(dirname "${BASH_SOURCE[0]}")"
rc=0
for s in control-flow edge-cases layers; do
  f="$here/$s.sh"
  [[ -f "$f" ]] || { echo "(skip: $s.sh not present yet)"; continue; }
  echo "######## $s ########"
  bash "$f" || rc=1
done
exit "$rc"
```

- [ ] **Step 5: Make executable and run the two existing suites**

Run:
```bash
cd /Volumes/Data/Workspace/dev/claude-plugins/cc-repete-plugin
chmod +x tests/smoke/*.sh
bash tests/smoke/all.sh
```
Expected: `control-flow` prints `RESULT: 19 passed, 0 failed`; `edge-cases` prints `RESULT: 6 passed, 0 failed`; `layers` prints `(skip: layers.sh not present yet)`; overall exit 0.

- [ ] **Step 6: Commit**

```bash
git add tests/smoke/lib.sh tests/smoke/control-flow.sh tests/smoke/edge-cases.sh tests/smoke/all.sh
git commit -m "test: relocate repete smoke harness into repo (tests/smoke), durable + sourceable"
```

---

## Task 1: Extract engine protocol to `templates/protocol.md` with fail-functional fallback

Move the hardcoded RULES heredoc (`stop-hook.sh:137-146`) into a shipped template the hook reads at runtime, with an inline fallback so a missing template never strips the sentinels. Apply the two protocol content edits the spec requires (§4): the "re-read all cards" rule becomes the catalog-consult rule, and a constitution-pointer line is added. The catalog itself is built in Task 2; here the protocol merely *references* it.

**Files:**
- Create: `templates/protocol.md`
- Modify: `hooks/stop-hook.sh:129-152` (the autonomous-continue branch)
- Test: `tests/smoke/layers.sh`

**Interfaces:**
- Consumes: `PHASE`, `NEXT`, `PAYLOAD_BODY`, `REPETE_DIR` (all already defined earlier in the hook).
- Produces: `assemble_reinject` behavior — the `reason` field now equals `PAYLOAD_BODY` + a blank line + the protocol text with `${PHASE}`/`${NEXT}` substituted. The protocol is read from `${CLAUDE_PLUGIN_ROOT}/templates/protocol.md`; if unreadable, `PROTO_FALLBACK` (inline) is used. Both sentinel rules and "work from files" survive in either path.

- [ ] **Step 1: Write the failing test in `tests/smoke/layers.sh`**

Create the file (first layer suite). The hook resolves the template via `$CLAUDE_PLUGIN_ROOT`; the harness points that at the repo root so the real `templates/protocol.md` is used.

```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

echo "== L1: protocol read from template, placeholders substituted =="
D="$ROOT/l1"; mkstate "$D" running true 1 0 0 '"g"' '"s"'
mktrans "$D/tr.jsonl" "working"
runhook "$D" "$D/tr.jsonl" "s"
echo "$OUT" | jq -e '.reason | contains("repete standing rules")' >/dev/null 2>&1; assert "protocol heading present in reason" $?
echo "$OUT" | jq -e '.reason | contains("iteration 2")' >/dev/null 2>&1; assert "NEXT placeholder substituted (iteration 2)" $?
echo "$OUT" | jq -e '.reason | contains("<repete-done>")' >/dev/null 2>&1; assert "done sentinel rule present" $?
echo "$OUT" | jq -e '.reason | contains("<repete-checkpoint>")' >/dev/null 2>&1; assert "checkpoint sentinel rule present" $?
echo "$OUT" | jq -e '.reason | contains(".repete/constitution.md")' >/dev/null 2>&1; assert "constitution pointer present in protocol" $?
echo "$OUT" | jq -e '.reason | test("\\$\\{PHASE\\}|\\$\\{NEXT\\}") | not' >/dev/null 2>&1; assert "no unsubstituted placeholders leak" $?

echo "== L2: protocol FALLBACK when template unreadable keeps both sentinels =="
D="$ROOT/l2"; mkstate "$D" running true 1 0 0 '"g"' '"s"'
mktrans "$D/tr.jsonl" "working"
OUT="$(CLAUDE_PROJECT_DIR="$D" CLAUDE_PLUGIN_ROOT="$ROOT/nonexistent-plugin-root" \
  bash -c 'printf "%s" "$0" | bash "$1"' \
  "$(jq -nc --arg tp "$D/tr.jsonl" --arg sid "s" '{transcript_path:$tp,session_id:$sid}')" \
  "$HOOK" 2>/dev/null)"
echo "$OUT" | jq -e '.decision=="block"' >/dev/null 2>&1; assert "fallback still blocks (loop alive)" $?
echo "$OUT" | jq -e '.reason | contains("<repete-done>")' >/dev/null 2>&1; assert "fallback has done sentinel" $?
echo "$OUT" | jq -e '.reason | contains("<repete-checkpoint>")' >/dev/null 2>&1; assert "fallback has checkpoint sentinel" $?
echo "$OUT" | jq -e '.reason | contains("files")' >/dev/null 2>&1; assert "fallback has work-from-files rule" $?
# Distinctive fallback phrasing the v1 heredoc does NOT contain — proves we hit
# the inline fallback path, not the old heredoc. (B3: keeps the red step red.)
echo "$OUT" | jq -e '.reason | contains("MISSION goal in .repete/MISSION.md is verifiably TRUE")' >/dev/null 2>&1; assert "fallback uses its distinctive phrasing (not v1 heredoc)" $?

summary
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Volumes/Data/Workspace/dev/claude-plugins/cc-repete-plugin && bash tests/smoke/layers.sh`
Expected: FAIL on L1 "constitution pointer present" (v1 protocol has no such line) and likely others; `templates/protocol.md` does not exist yet so the hook still uses the heredoc.

- [ ] **Step 3: Write `templates/protocol.md`**

```markdown

--- repete standing rules (phase ${PHASE} · iteration ${NEXT}) ---
- Re-read .repete/MISSION.md and .repete/todo-next.md BEFORE acting. Work from files and git, not from memory in this conversation.
- .repete/constitution.md holds the user's hard invariants for this project. Treat it as authoritative; never violate it to make progress.
- Consult the lessons catalog injected above. Read only the .repete/lessons/ cards whose tags match what you are about to do — do not bulk-read them all.
- The moment you notice work outside this loop's exit goal, append it to .repete/todo-next.md (one line: what + why + where). Do not chase it now.
- When you hit a mistake, dead-end, or a fix that did not work, write a lesson card to .repete/lessons/ in the format the template defines. Reflect briefly: what you tried, what happened, the rule for next time.
- When THIS loop's exit goal is satisfied (and only then): output a <repete-checkpoint>...</repete-checkpoint> block containing your proposed next-loop payload — seeded from .repete/todo-next.md and what you learned — then stop. The user approves it before the next loop starts.
- Only when the MISSION goal stated in .repete/MISSION.md is unequivocally and verifiably TRUE: output <repete-done> with that exact goal string </repete-done>. Never emit either sentinel just to escape the loop.
```

- [ ] **Step 4: Replace the heredoc + assembly in `hooks/stop-hook.sh`**

Replace lines 129-152 (the entire `# ---- (3) autonomous continue` block from `NEXT=` through `exit 0`) with:

```bash
# ---- (3) autonomous continue: block + re-inject --------------------------
NEXT=$((ITERATION + 1))
set_fm iteration "$NEXT"

# Everything after the SECOND '---'. Print-before-increment so a '---' horizontal
# rule inside the body is preserved, not swallowed (I1).
PAYLOAD_BODY="$(awk 'p{print} /^---[[:space:]]*$/{c++; if(c==2)p=1}' "$STATE_FILE")"

# --- engine protocol (frozen, hook-versioned) -----------------------------
# Read the shipped protocol template; fall back to an inline core if it is
# unreadable (missing/botched install). Fail-functional: the loop must never
# lose its two sentinels, matching the fail-open-on-missing-jq philosophy.
PROTO_FALLBACK='
--- repete standing rules (phase ${PHASE} · iteration ${NEXT}) ---
- Work from files and git, not from memory in this conversation.
- When THIS loop'"'"'s exit goal is satisfied (and only then): output a <repete-checkpoint>...</repete-checkpoint> block with your proposed next-loop payload, then stop.
- Only when the MISSION goal in .repete/MISSION.md is verifiably TRUE: output <repete-done> with that exact goal string </repete-done>. Never emit either sentinel just to escape the loop.'
PROTO="$(cat "${CLAUDE_PLUGIN_ROOT:-}/templates/protocol.md" 2>/dev/null)"
[[ -n "$PROTO" ]] || PROTO="$PROTO_FALLBACK"
PROTO="${PROTO//'${PHASE}'/$PHASE}"
PROTO="${PROTO//'${NEXT}'/$NEXT}"

# --- assemble re-inject: brief, [catalog], [constitution], protocol LAST ---
REINJECT="$PAYLOAD_BODY"
REINJECT+=$'\n'"$PROTO"

jq -n --arg r "$REINJECT" --arg m "🔄 repete · phase ${PHASE} · iteration ${NEXT}" \
  '{decision:"block", reason:$r, systemMessage:$m}'
exit 0
```

(Tasks 2 and 3 insert the catalog and constitution into the `REINJECT` assembly between brief and protocol.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd /Volumes/Data/Workspace/dev/claude-plugins/cc-repete-plugin && bash tests/smoke/layers.sh`
Expected: L1 (6 assertions) and L2 (4 assertions) all PASS.

- [ ] **Step 6: Run the full suite — no control-flow regression**

Run: `bash tests/smoke/all.sh`
Expected: control-flow 19/0, edge-cases 6/0, layers 11/0, exit 0. (Diff against Task 0 baseline: control-flow + edge-cases unchanged.)

- [ ] **Step 7: Commit**

```bash
git add templates/protocol.md hooks/stop-hook.sh tests/smoke/layers.sh
git commit -m "feat(hook): extract engine protocol to templates/protocol.md with inline fallback"
```

---

## Task 2: Lessons catalog builder (metadata-only) wired into the re-inject

Add a catalog builder that scans `.repete/lessons/`, parses one frontmatter line per card, ranks by severity then hits, caps at `lesson_catalog_cap` (default 8) with an overflow note, and is robust to malformed cards. Inject the catalog between the brief and the protocol. Card *bodies* never enter the re-inject.

**Files:**
- Modify: `hooks/stop-hook.sh` (add `card_field` + `build_catalog` near the other helpers ~line 45; read `lesson_catalog_cap`; insert catalog into assembly)
- Test: `tests/smoke/layers.sh` (append)

**Interfaces:**
- Consumes: `REPETE_DIR`, `fm` (frontmatter reader).
- Produces:
  - `card_field FILE KEY` → echoes the frontmatter value for `KEY` from a lesson card (handles the leading `<!-- -->` comment by keying off the first `---…---` block); empty if absent.
  - `build_catalog CAP` → echoes the formatted catalog (header + ranked, capped lines + optional overflow), or nothing if no valid cards. Skips `_TEMPLATE.md` and any card missing `slug` or a recognized `severity`.
  - `CATALOG_CAP` variable read from `lesson_catalog_cap` frontmatter (default 8).
  - `CATALOG` variable inserted into `REINJECT` between `PAYLOAD_BODY` and `PROTO`.

- [ ] **Step 1: Write failing tests (append to `tests/smoke/layers.sh`, before the final `summary`)**

```bash
echo "== L3: catalog ranks by severity then hits, excludes template + malformed =="
D="$ROOT/l3"; mkstate "$D" running true 1 0 0 '"g"' '"s"'
mkcard "$D" "001-low-old"   "hook,shell"  low    1
mkcard "$D" "003-high-hot"  "jest,esm"    high   4
mkcard "$D" "007-med-two"   "async,test"  medium 2
# malformed: missing severity -> must be skipped
cat > "$D/.repete/lessons/099-broken.md" <<'EOF'
---
slug: 099-broken
tags: [x]
hits: 9
---
no severity here
EOF
# _TEMPLATE.md must be excluded
cp "$D/.repete/lessons/001-low-old.md" "$D/.repete/lessons/_TEMPLATE.md"
mktrans "$D/tr.jsonl" "working"
runhook "$D" "$D/tr.jsonl" "s"
echo "$OUT" | jq -e '.reason | contains("Known lessons")' >/dev/null 2>&1; assert "catalog header present" $?
echo "$OUT" | jq -e '.reason | contains("003-high-hot")' >/dev/null 2>&1; assert "high card present" $?
echo "$OUT" | jq -e '.reason | contains("099-broken") | not' >/dev/null 2>&1; assert "malformed card excluded" $?
echo "$OUT" | jq -e '.reason | contains("_TEMPLATE") | not' >/dev/null 2>&1; assert "template excluded" $?
# ordering: high appears before medium appears before low
echo "$OUT" | jq -r '.reason' | awk '/003-high-hot/{h=NR} /007-med-two/{m=NR} /001-low-old/{l=NR} END{exit !(h<m && m<l)}'; assert "ranked high<medium<low" $?
# no card body prose leaks
echo "$OUT" | jq -e '.reason | contains("do the thing") | not' >/dev/null 2>&1; assert "no card body in re-inject" $?
# no inline frontmatter-comment text leaks (B1: card_field must strip trailing #...)
echo "$OUT" | jq -e '.reason | contains("used to decide") | not' >/dev/null 2>&1; assert "no inline # comment leaked from tags line" $?
echo "$OUT" | jq -e '.reason | contains("how badly it bit") | not' >/dev/null 2>&1; assert "no inline # comment leaked from severity line" $?
# the commented high card (003) must still be ranked top despite its inline comment
echo "$OUT" | jq -r '.reason' | awk '/003-high-hot/{print; exit}' | grep -q 'high'; assert "commented card parsed (severity survived strip)" $?

echo "== L4: cap caps the catalog and emits overflow note =="
D="$ROOT/l4"; mkstate "$D" running true 1 0 2 '"g"' '"s"'   # ctx budget unused here
# override cap to 2 via frontmatter
perl -0777 -pi -e 's/lesson_catalog_cap: 8/lesson_catalog_cap: 2/' "$D/.repete/loop.local.md"
mkcard "$D" "a-high" "t" high 5
mkcard "$D" "b-high" "t" high 4
mkcard "$D" "c-high" "t" high 3
mktrans "$D/tr.jsonl" "working"
runhook "$D" "$D/tr.jsonl" "s"
echo "$OUT" | jq -e '.reason | contains("+1 more")' >/dev/null 2>&1; assert "overflow note for 3 cards cap 2" $?
# exactly 2 card lines shown. Count real catalog rows (two-space indent, a slug,
# then the "[tags]" field) and exclude the "… +N more" overflow line. Decoupled
# from %-Ns padding width and from the specific slug names (B4).
[[ "$(echo "$OUT" | jq -r '.reason' | grep -E '^  [^ ].*\[' | grep -vc 'more —')" -eq 2 ]]; assert "exactly cap (2) cards shown" $?

echo "== L5: no lessons dir / empty -> no catalog, loop still continues =="
D="$ROOT/l5"; mkstate "$D" running true 1 0 0 '"g"' '"s"'
rm -rf "$D/.repete/lessons"
mktrans "$D/tr.jsonl" "working"
runhook "$D" "$D/tr.jsonl" "s"
echo "$OUT" | jq -e '.decision=="block"' >/dev/null 2>&1; assert "no lessons dir -> still blocks" $?
echo "$OUT" | jq -e '.reason | contains("Known lessons") | not' >/dev/null 2>&1; assert "no catalog header when no cards" $?
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/smoke/layers.sh`
Expected: L3/L4 FAIL (no catalog yet); L5 "no catalog header" PASS by accident, "still blocks" PASS.

- [ ] **Step 3: Add `card_field` + `build_catalog` to `hooks/stop-hook.sh`**

Insert after the `emit()` helper (after line 45):

```bash
# ---- lesson catalog helpers ----------------------------------------------
# Read one frontmatter value from a lesson card. The card template carries a
# leading <!-- ... --> comment BEFORE its '---' block, so key off the first
# '---'-delimited block (f==1), exactly as the state-file reader does.
card_field() { # file key
  # Strip the "key: " prefix, then any trailing " # comment" (the shipped
  # lesson-card template carries inline comments on its frontmatter lines —
  # e.g. `severity: high   # how badly it bit`), then trim surrounding space.
  # Without the comment-strip a filled card's severity becomes "high  # …",
  # which fails the case match in build_catalog and silently drops the card.
  awk -v k="$2" '
    BEGIN{f=0}
    /^---[[:space:]]*$/{f++; next}
    f==1 && index($0, k":")==1 {
      sub("^"k":[[:space:]]*","")
      sub(/[[:space:]]*#.*$/,"")
      gsub(/^[[:space:]]+|[[:space:]]+$/,"")
      print; exit
    }
    f>=2{exit}
  ' "$1"
}

# Build a metadata-only catalog: one line per valid card, ranked severity
# (high>medium>low) then hits (desc), capped, with an overflow note. Robust:
# any card missing slug or a recognized severity is skipped silently, never
# crashing the builder or emitting a garbled line (spec §5 parser robustness).
build_catalog() { # cap
  local cap="$1" dir="$REPETE_DIR/lessons"
  [[ -d "$dir" ]] || return 0
  local f slug sev hits tags rank rows="" total=0
  for f in "$dir"/*.md; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == "_TEMPLATE.md" ]] && continue
    slug="$(card_field "$f" slug)"
    sev="$(card_field "$f" severity)"
    [[ -n "$slug" && -n "$sev" ]] || continue
    case "$sev" in
      high) rank=0 ;; medium) rank=1 ;; low) rank=2 ;;
      *) continue ;;
    esac
    hits="$(card_field "$f" hits)"; [[ "$hits" =~ ^[0-9]+$ ]] || hits=1
    tags="$(card_field "$f" tags | tr -d '[] ')"
    rows+="$(printf '%d\t%09d\t%s\t%s\t%s\t%s' "$rank" "$((999999999 - hits))" "$slug" "$tags" "$sev" "$hits")"$'\n'
    total=$((total + 1))
  done
  [[ "$total" -gt 0 ]] || return 0
  local shown="$total"
  [[ "$cap" -gt 0 ]] && shown="$cap"
  printf 'Known lessons (consult before acting; Read only the relevant ones):\n'
  printf '%s' "$rows" | sort -t$'\t' -k1,1n -k2,2n | head -n "$shown" \
    | awk -F'\t' '{printf "  %-22s [%s] %-6s hits:%s\n", $3, $4, $5, $6}'
  if [[ "$cap" -gt 0 && "$total" -gt "$cap" ]]; then
    printf '  … +%d more — grep .repete/lessons/\n' "$((total - cap))"
  fi
}
```

- [ ] **Step 4: Read the cap and insert the catalog into assembly**

In the autonomous-continue branch, after `PAYLOAD_BODY=...` and before the protocol block, add:

```bash
# --- lessons catalog (metadata only; bodies are agent-retrieved on demand) -
CATALOG_CAP="$(fm lesson_catalog_cap)"; [[ "$CATALOG_CAP" =~ ^[0-9]+$ ]] || CATALOG_CAP=8
CATALOG="$(build_catalog "$CATALOG_CAP")"
```

Then change the assembly block to insert the catalog between brief and protocol:

```bash
# --- assemble re-inject: brief, [catalog], [constitution], protocol LAST ---
REINJECT="$PAYLOAD_BODY"
[[ -n "$CATALOG" ]] && REINJECT+=$'\n\n'"$CATALOG"
REINJECT+=$'\n'"$PROTO"
```

- [ ] **Step 5: Run to verify pass**

Run: `bash tests/smoke/layers.sh`
Expected: L1–L5 all PASS.

- [ ] **Step 6: Full suite regression**

Run: `bash tests/smoke/all.sh`
Expected: control-flow 19/0, edge-cases 6/0, layers all pass, exit 0.

- [ ] **Step 7: Commit**

```bash
git add hooks/stop-hook.sh tests/smoke/layers.sh
git commit -m "feat(hook): metadata-only lessons catalog (ranked, capped, malformed-safe)"
```

---

## Task 3: User constitution layer + template + scaffold + MISSION pointer

Add the user-owned constitution: read `.repete/constitution.md` and inject it between catalog and protocol, but skip it when it is absent or contains only comments/blank lines (an unfilled starter must not bloat the re-inject). Ship the starter template, have `/repete` scaffold it, and convert MISSION.md's Constraints section to a pointer so constraints are single-sourced.

**Files:**
- Create: `templates/constitution.md`
- Modify: `hooks/stop-hook.sh` (constitution reader + assembly)
- Modify: `templates/MISSION.md` (Constraints → pointer)
- Modify: `commands/repete.md` (scaffold writes constitution + `lesson_catalog_cap`)
- Test: `tests/smoke/layers.sh` (append)

**Interfaces:**
- Consumes: `REPETE_DIR`; the assembly `REINJECT` from Task 2.
- Produces: `CONSTITUTION` variable — the constitution text with HTML comments and blank lines stripped for the emptiness check; injected verbatim (original text) under a header only when non-empty after stripping.

- [ ] **Step 1: Write failing tests (append to `tests/smoke/layers.sh` before `summary`)**

```bash
echo "== L6: real constitution injected before protocol, after catalog; comments stripped =="
D="$ROOT/l6"; mkstate "$D" running true 1 0 0 '"g"' '"s"'
cat > "$D/.repete/constitution.md" <<'EOF'
<!-- editing note the agent must never see -->
Do not touch the db/ directory.
Always run: make test
EOF
mkcard "$D" "001-x" "t" high 1
mktrans "$D/tr.jsonl" "working"
runhook "$D" "$D/tr.jsonl" "s"
echo "$OUT" | jq -e '.reason | contains("Do not touch the db/ directory")' >/dev/null 2>&1; assert "constitution content injected" $?
echo "$OUT" | jq -e '.reason | contains("editing note the agent must never see") | not' >/dev/null 2>&1; assert "HTML comment stripped from injected constitution (S3)" $?
# order: catalog (Known lessons) before constitution before protocol (standing rules)
echo "$OUT" | jq -r '.reason' | awk '/Known lessons/{c=NR} /Do not touch the db/{k=NR} /repete standing rules/{p=NR} END{exit !(c<k && k<p)}'; assert "order catalog<constitution<protocol" $?

echo "== L7: comment-only / empty constitution is skipped (no bloat) =="
D="$ROOT/l7"; mkstate "$D" running true 1 0 0 '"g"' '"s"'
cat > "$D/.repete/constitution.md" <<'EOF'
<!--
  Starter. Fill in your project's hard invariants below.
-->

EOF
mktrans "$D/tr.jsonl" "working"
runhook "$D" "$D/tr.jsonl" "s"
echo "$OUT" | jq -e '.reason | contains("project invariants") | not' >/dev/null 2>&1; assert "comment-only constitution skipped" $?
echo "$OUT" | jq -e '.decision=="block"' >/dev/null 2>&1; assert "loop still continues" $?

echo "== L8: missing constitution is skipped silently =="
D="$ROOT/l8"; mkstate "$D" running true 1 0 0 '"g"' '"s"'
mktrans "$D/tr.jsonl" "working"
runhook "$D" "$D/tr.jsonl" "s"
echo "$OUT" | jq -e '.reason | contains("project invariants") | not' >/dev/null 2>&1; assert "absent constitution -> no header" $?

echo "== L8b: catalog is rebuilt FRESH each Stop — a card added between Stops appears (spec §5) =="
D="$ROOT/l8b"; mkstate "$D" running true 1 0 0 '"g"' '"s"'
mkcard "$D" "001-first" "t" high 1
mktrans "$D/tr.jsonl" "working"
runhook "$D" "$D/tr.jsonl" "s"
echo "$OUT" | jq -e '.reason | contains("002-added") | not' >/dev/null 2>&1; assert "card not yet present before it exists" $?
mkcard "$D" "002-added" "t" high 2          # add a card between Stops
runhook "$D" "$D/tr.jsonl" "s"               # second Stop, same fixture
echo "$OUT" | jq -e '.reason | contains("002-added")' >/dev/null 2>&1; assert "newly-added card appears in next catalog (fresh build)" $?
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/smoke/layers.sh`
Expected: L6 FAIL (no constitution read yet), L7/L8/L8b mostly PASS by accident (L8b's "appears" assertion fails until the catalog exists — but the catalog landed in Task 2, so L8b passes here; it guards against a future regression to a cached index).

- [ ] **Step 3: Add the constitution reader to `hooks/stop-hook.sh`**

In the autonomous-continue branch, after the `CATALOG=...` lines and before the protocol block, add:

```bash
# --- user constitution (frozen, user-authored) ----------------------------
# Inject verbatim ONLY if it has real content. An unfilled starter is all HTML
# comments + blanks; injecting that every iteration is pure bloat, so treat
# "comments-and-whitespace only" as empty and skip (extends spec §7 "empty ->
# skip" to "effectively-empty -> skip").
CONSTITUTION=""
CONST_FILE="$REPETE_DIR/constitution.md"
if [[ -f "$CONST_FILE" ]]; then
  CONST_RAW="$(cat "$CONST_FILE" 2>/dev/null)"
  # Strip <!-- ... --> comment blocks (keep everything else). The stripped text is
  # what gets injected — comment noise must not ride every re-inject (spec §7
  # "stay short"). This is stricter-but-aligned with the spec's "verbatim": we
  # inject the user's real rules, minus HTML comments.
  CONST_NOCOMMENT="$(printf '%s' "$CONST_RAW" | perl -0777 -pe 's/<!--.*?-->//gs')"
  # Emptiness test: also drop blank lines; if nothing real remains, skip entirely
  # (an unfilled all-comments starter -> empty -> not injected).
  CONST_REAL="$(printf '%s' "$CONST_NOCOMMENT" | grep -v '^[[:space:]]*$' || true)"
  if [[ -n "$CONST_REAL" ]]; then
    # Trim leading + trailing blank lines (a stripped comment block leaves gaps),
    # but keep blank lines BETWEEN rules. Portable: no tac/tail -r (macOS lacks tac).
    # awk #1 drops leading blanks; awk #2 buffers and prints up to the last non-blank.
    CONSTITUTION="$(printf '%s' "$CONST_NOCOMMENT" \
      | awk 'NF{p=1} p' \
      | awk '{a[NR]=$0} END{last=NR; while(last>0 && a[last]~/^[[:space:]]*$/)last--; for(i=1;i<=last;i++)print a[i]}')"
  fi
fi
```

- [ ] **Step 4: Insert constitution into the assembly**

Update the assembly block to its final form:

```bash
# --- assemble re-inject: brief, [catalog], [constitution], protocol LAST ---
REINJECT="$PAYLOAD_BODY"
[[ -n "$CATALOG" ]] && REINJECT+=$'\n\n'"$CATALOG"
[[ -n "$CONSTITUTION" ]] && REINJECT+=$'\n\n--- project invariants (.repete/constitution.md) ---\n'"$CONSTITUTION"
REINJECT+=$'\n'"$PROTO"
```

- [ ] **Step 5: Run to verify pass**

Run: `bash tests/smoke/layers.sh`
Expected: L1–L8 all PASS.

- [ ] **Step 6: Write `templates/constitution.md`**

```markdown
<!--
  .repete/constitution.md — your project's HARD INVARIANTS for this repete run.

  This file is re-injected into the loop on every iteration, just before the
  engine protocol. Keep it SHORT and CONFLICT-FREE — a handful of imperative
  rules. Rule count and contradiction degrade adherence; repetition does not.

  Put here: don't-touch dirs, API/contract stability, the exact test command,
  commit conventions, security/no-network rules — things that are true for the
  WHOLE mission and must never be violated to make progress.

  Do NOT put here: this loop's current task (that lives in the evolving brief in
  loop.local.md) or past lessons (those live as cards in .repete/lessons/).

  An all-comments file like this one is treated as empty and not injected.
  Delete these comments and write your rules below to activate it.
-->
```

- [ ] **Step 7: Convert `templates/MISSION.md` Constraints to a pointer**

Replace the `## Constraints` section (currently lines 26-27, the heading plus its `- <hard rules…>` bullet) with:

```markdown
## Constraints

Hard invariants live in `.repete/constitution.md` (single source — re-injected into
the loop each iteration). Edit that file, not this section.
```

- [ ] **Step 8: Update `commands/repete.md` scaffold step**

In `commands/repete.md`, in the "## 2. Scaffold `.repete/`" section, the `.repete/loop.local.md` bullet lists frontmatter keys. Add `lesson_catalog_cap` to that list. Replace the frontmatter sub-bullet block (the lines from "Fill the frontmatter:" through "`status: running`...") so it includes the cap, and add a new top-level bullet for the constitution. Concretely, add these two edits:

(a) In the `loop.local.md` frontmatter list, after the `max_iterations, context_budget_lines` bullet, add:
```markdown
  - `lesson_catalog_cap`: max lesson lines surfaced in the catalog each iteration
    (default 8; 0 = uncapped — only for small projects).
```

(b) After the `.repete/lessons/` bullet, add a new bullet:
```markdown
- `.repete/constitution.md` — copy from `${CLAUDE_PLUGIN_ROOT}/templates/constitution.md`.
  This is the user's hard-invariants layer, re-injected each iteration. After copying the
  commented starter, ask the user (once, briefly) whether they have hard invariants to seed
  it (don't-touch dirs, the test command, API-stability, no-push, etc.). If they name any,
  write them in as imperative one-liners and delete the comment block so it activates. If
  they have none, leave the starter as-is (it stays inert until filled). Do NOT force this as
  a blocking prompt — offer it and move on.
```

- [ ] **Step 9: Full suite regression**

Run: `bash tests/smoke/all.sh`
Expected: control-flow 19/0, edge-cases 6/0, layers all pass, exit 0.

- [ ] **Step 10: Commit**

```bash
git add hooks/stop-hook.sh templates/constitution.md templates/MISSION.md commands/repete.md tests/smoke/layers.sh
git commit -m "feat: user constitution layer (effectively-empty-skip) + scaffold + MISSION pointer"
```

---

## Task 4: Close the "Known traps" back door (command + template surgery)

The catalog keeps lesson *bodies* out of the hook re-inject, but v1 re-couples them at the checkpoint: `templates/loop.local.md` has a `## Known traps` section, and `repete-continue.md` step 3 says to "pull the cards" into it — and the brief body is re-injected every iteration. Close it: the section becomes a pointer, and the checkpoint step stops copying card content. Also extend `repete-status.md` to preview the catalog and surface the constitution.

These are Markdown instruction files, not executable code — the "tests" are content assertions (required phrasing present, forbidden phrasing absent). The real integration check is the live round-trip in Task 6.

**Files:**
- Modify: `templates/loop.local.md` (Known traps section → pointer)
- Modify: `commands/repete-continue.md` (checkpoint step 3 rewrite; rehydrate reads constitution)
- Modify: `commands/repete-status.md` (catalog preview + constitution surface)
- Test: `tests/smoke/docs.sh` (new — content assertions)

**Interfaces:**
- Consumes: nothing at runtime (these are agent-facing docs).
- Produces: the guarantee that no command instructs the agent to copy lesson card bodies into any re-injected layer.

- [ ] **Step 1: Write failing content-assertion test `tests/smoke/docs.sh`**

```bash
#!/usr/bin/env bash
# Content assertions for the agent-facing command/template files. These are not
# executable code; we assert required phrasing is present and the back-door
# phrasing (copying lesson bodies into the brief) is gone.
set -uo pipefail
ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
chk() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

LL="$ROOT_REPO/templates/loop.local.md"
RC="$ROOT_REPO/commands/repete-continue.md"
RS="$ROOT_REPO/commands/repete-status.md"

echo "== D1: loop.local.md Known-traps is a pointer, not a content sink =="
chk "loop.local.md mentions consult/catalog (pointer language)" "grep -qiE 'consult|catalog' '$LL'"
# Anchor on the v1 PLACEHOLDER token being gone, not on a substring of prose a
# future correct edit might legitimately contain (S5). The v1 section is the only
# place with a '<seeded' angle-bracket placeholder.
chk "loop.local.md v1 '<seeded...' placeholder removed" "! grep -qi '<seeded' '$LL'"
chk "loop.local.md forbids pasting card bodies (pointer intent explicit)" "grep -qiE 'never hold card bodies|do not paste|not a content sink' '$LL'"
chk "loop.local.md has lesson_catalog_cap frontmatter" "grep -q 'lesson_catalog_cap:' '$LL'"

echo "== D2: repete-continue checkpoint step no longer copies card content =="
chk "repete-continue does NOT say 'pull the cards'" "! grep -qi 'pull the cards' '$RC'"
chk "repete-continue references the catalog mechanism" "grep -qiE 'catalog|agent-retriev|on demand' '$RC'"
chk "repete-continue rehydrate reads constitution.md" "grep -q 'constitution.md' '$RC'"

echo "== D3: repete-status previews catalog + constitution =="
chk "repete-status mentions catalog preview" "grep -qi 'catalog' '$RS'"
chk "repete-status surfaces constitution.md" "grep -q 'constitution.md' '$RS'"

echo; echo "==== DOCS: $PASS passed, $FAIL failed ===="
[[ "$FAIL" -eq 0 ]]
```

Also add `docs` to the loop in `tests/smoke/all.sh`:
```bash
for s in control-flow edge-cases layers docs; do
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/smoke/docs.sh`
Expected: D1 "no longer says…", D2 "does NOT say pull the cards", D2 constitution, D3 catalog all FAIL.

- [ ] **Step 3: Rewrite the `## Known traps` section in `templates/loop.local.md`**

Replace the section (currently lines 27-29: the `## Known traps (from .repete/lessons/)` heading and its `<seeded… >` placeholder) with:

```markdown
## Known traps

The hook injects a lessons **catalog** (slug · tags · severity · hits) into every
iteration automatically. Consult it and `Read` only the relevant `.repete/lessons/`
cards on demand — do not paste card contents here. This section stays a pointer; it
must never hold card bodies (that would re-inject them every iteration).
```

- [ ] **Step 4: Rewrite checkpoint step 3 in `commands/repete-continue.md`**

In the `## status: paused-checkpoint` section, replace step 3 (currently: "3. Refresh the **Known traps** section of the new payload from `.repete/lessons/`… so the loop starts forewarned.") with:

```markdown
3. Do NOT copy lesson cards into the payload body. Lessons are surfaced automatically:
   the hook builds a metadata catalog from `.repete/lessons/` every iteration and the
   agent `Read`s the relevant cards on demand. The new payload's "Known traps" section
   stays a pointer (see the template) — never a content sink.
```

- [ ] **Step 5: Add constitution to the rehydrate boot manifest in `commands/repete-continue.md`**

In the `## status: paused-context` section, step 1 lists the read order ("Read, in order: `.repete/MISSION.md`, the body of `.repete/loop.local.md`, `.repete/todo-next.md`, the relevant cards in `.repete/lessons/`, and `git log…`"). Insert `.repete/constitution.md` into that list, after `loop.local.md`:

```markdown
1. Read, in order: `.repete/MISSION.md`, the body of `.repete/loop.local.md`,
   `.repete/constitution.md` (the user's hard invariants), `.repete/todo-next.md`, the
   relevant cards in `.repete/lessons/`, and `git log --oneline -15`. If the `remember`
   plugin is active, also read `.remember/now.md`.
```

- [ ] **Step 6: Extend `commands/repete-status.md`**

In the bullet list of what to present, after the **Lessons** bullet, add two bullets:

```markdown
- **Lessons catalog (as the loop sees it)**: render the same ranked, capped catalog the
  hook would inject — for each card (excluding `_TEMPLATE.md`) show `slug · [tags] ·
  severity · hits`, ranked by severity then hits, capped at `lesson_catalog_cap` (default
  8) with a `+N more` note if it overflows. This previews exactly what rides the re-inject.
- **Constitution**: report whether `.repete/constitution.md` exists and has real content
  (not just the commented starter); if it is large (well over ~40 lines combined with the
  protocol), warn that long frozen layers degrade adherence (rule count is the killer).
```

- [ ] **Step 7: Run to verify pass**

Run: `bash tests/smoke/docs.sh`
Expected: D1–D3 all PASS.

- [ ] **Step 8: Full suite**

Run: `bash tests/smoke/all.sh`
Expected: control-flow 19/0, edge-cases 6/0, layers all pass, docs all pass, exit 0.

- [ ] **Step 9: Commit**

```bash
git add templates/loop.local.md commands/repete-continue.md commands/repete-status.md tests/smoke/docs.sh tests/smoke/all.sh
git commit -m "fix: close Known-traps back door — lessons stay catalog+on-demand, never re-injected bodies"
```

---

## Task 5: ShellCheck + full-assembly integration assertion

One assertion that exercises the *whole* assembled re-inject in correct order with all four layers live simultaneously (the per-task tests checked layers in isolation), plus a static lint pass on the modified hook.

**Files:**
- Test: `tests/smoke/layers.sh` (append integration assertion)

- [ ] **Step 1: Append the full-stack assertion to `tests/smoke/layers.sh` (before `summary`)**

```bash
echo "== L9: all four layers present, in order, in one re-inject =="
D="$ROOT/l9"; mkstate "$D" running true 1 0 0 '"all green"' '"s"'
printf '%s\n' "Never push to main." > "$D/.repete/constitution.md"
mkcard "$D" "001-trap" "build,ci" high 3
mktrans "$D/tr.jsonl" "mid-loop work"
runhook "$D" "$D/tr.jsonl" "s"
echo "$OUT" | jq -r '.reason' | awk '
  /BODY-LINE-ONE/{b=NR}
  /Known lessons/{c=NR}
  /Never push to main/{k=NR}
  /repete standing rules/{p=NR}
  END{exit !(b<c && c<k && k<p)}'; assert "order brief<catalog<constitution<protocol" $?
echo "$OUT" | jq -e '.reason | contains("001-trap")' >/dev/null 2>&1; assert "catalog card present in full stack" $?
echo "$OUT" | jq -e '.reason | contains("do the thing") | not' >/dev/null 2>&1; assert "no card body leaked in full stack" $?
```

- [ ] **Step 2: Run to verify it passes** (assembly already built in Tasks 1-3)

Run: `bash tests/smoke/layers.sh`
Expected: L1–L9 all PASS.

- [ ] **Step 3: ShellCheck the hook (if available)**

Run:
```bash
command -v shellcheck >/dev/null 2>&1 && shellcheck -S warning hooks/stop-hook.sh || echo "shellcheck not installed — skipping (not a hard dep)"
```
Expected: no warnings, or the skip message. If shellcheck flags the new helpers, fix genuine issues (unquoted expansions, etc.); the `${var//'${PHASE}'/...}` literal-replace pattern is intentional and correct.

- [ ] **Step 4: Full suite final green**

Run: `bash tests/smoke/all.sh && echo "ALL SUITES GREEN"`
Expected: every suite passes, `ALL SUITES GREEN` printed, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tests/smoke/layers.sh
git commit -m "test: full four-layer assembly integration assertion"
```

---

## Task 6: Live round-trip verification + memory update

The synthetic harness proves the hook logic; only a live mission proves the real Stop→block→re-inject round-trip carries the layered payload in an actual session. Then record the roadmap reprioritization in project memory.

**Files:**
- Runtime only (creates and removes `.repete/` smoke state); updates the auto-memory file.

- [ ] **Step 1: Scaffold a throwaway live mission with all layers populated**

Create `.repete/` state by hand (mirrors what `/repete` would write), with a real constitution and one lesson card so the live re-inject exercises every layer:
- `.repete/MISSION.md` with `GOAL: proof2.txt contains LAYERED-OK`
- `.repete/loop.local.md` frontmatter: `active: true, phase: 1, iteration: 1, session_id: "", max_iterations: 3, context_budget_lines: 100000, mission_goal: "proof2.txt contains LAYERED-OK", lesson_catalog_cap: 8, status: running`; body brief: iteration 1 writes `.repete/smoke2/proof2.txt` = `PENDING2` (no sentinel); iteration 2 overwrites with `LAYERED-OK`, verifies, emits `<repete-done>proof2.txt contains LAYERED-OK</repete-done>`.
- `.repete/constitution.md` with one real line: `Touch only files under .repete/smoke2/.`
- `.repete/lessons/001-live.md` a valid card (slug/tags/severity/hits).
- `.repete/todo-next.md` header only.

- [ ] **Step 2: Run iteration 1**

Per the brief: confirm `proof2.txt` absent, write `PENDING2`, read it back, then stop with no sentinel.

- [ ] **Step 3: Verify the live re-inject carried all layers**

When the Stop hook blocks and re-injects, confirm in the injected text that you can see: the brief body, the `Known lessons` catalog line for `001-live`, the `project invariants` line `Touch only files under .repete/smoke2/`, and the `repete standing rules` protocol with `iteration 2`. Confirm `.repete/loop.local.md` `iteration` is now 2 and `session_id` was auto-stamped. State explicitly which layers were observed.

- [ ] **Step 4: Run iteration 2 and finish**

Overwrite `proof2.txt` with `LAYERED-OK`, read back to confirm exact content, emit `<repete-done>proof2.txt contains LAYERED-OK</repete-done>`. Confirm the hook tears down: `status: done`, `active: false`.

- [ ] **Step 5: Clean up throwaway state**

Run:
```bash
rm -rf /Volumes/Data/Workspace/dev/claude-plugins/cc-repete-plugin/.repete
```
(Rollback note: this only removes throwaway smoke state; the plugin's real state lives in `templates/`, `commands/`, `hooks/`, `tests/`, none under `.repete/`.)

- [ ] **Step 6: Update project memory**

Update `/Users/redux/.claude/projects/-Volumes-Data-Workspace-dev-claude-plugins-cc-repete-plugin/memory/repete-plugin.md`: record that v2 is now **memory layering** (four-layer MemGPT split: protocol/constitution/evolving-brief/lessons-catalog), that the original "mission as N named phases" slipped to v3+, and that the external runner is deferred to evidence-gated v3. Keep it to a few lines; link the spec and plan paths.

- [ ] **Step 7: Commit (docs/memory only — no code)**

```bash
git add docs/superpowers/plans/2026-06-20-repete-memory-layering.md
git commit -m "docs: repete v2 memory-layering implementation plan"
```
(The memory file lives outside the repo; it is not committed here.)

---

## Self-Review

**1. Spec coverage** — every spec section maps to a task:
- §2 four layers → Tasks 1 (protocol), 2 (catalog), 3 (constitution), brief already exists.
- §2 boundary invariant (protocol hook-owned, not user-editable) → Task 1 (template in `templates/`, not `.repete/`).
- §3 assembly order (brief<catalog<constitution<protocol-last) → built across Tasks 1-3, asserted L9 (Task 5).
- §4 protocol extraction + `${PHASE}/${NEXT}` + fail-functional fallback → Task 1 (L1, L2).
- §5 catalog (ranked, capped, overflow, parser-robust, metadata-only) → Task 2 (L3, L4, L5). Soft-ranking honesty is documentation, captured in protocol/status wording.
- §5 back-door closure (loop.local.md + repete-continue) → Task 4 (D1, D2).
- §6 changes-by-file → distributed: protocol.md (T1), catalog (T2), constitution.md/MISSION.md/repete.md (T3), loop.local.md/repete-continue.md/repete-status.md (T4).
- §7 guardrails (fail-functional, no bodies, short frozen layers) → fallback (T1), catalog metadata-only (T2, asserted "no card body"), over-length warning (T4 status).
- §10 resolutions: cap=8 default (T2/T3 frontmatter), seeding offer-not-prompt (T3 step 8b), constraints single-source (T3 MISSION pointer).
- §9 out-of-scope (`wc -c`, no-progress, runner, named phases, global lessons) → correctly NOT in any task; memory update (T6) records the reprioritization.

**2. Placeholder scan** — no "TBD"/"handle edge cases"/"similar to Task N". Every code step shows complete code; every command/template edit quotes the replacement text verbatim.

**3. Type/name consistency** — `card_field`, `build_catalog`, `CATALOG_CAP`, `CATALOG`, `CONSTITUTION`, `PROTO`, `PROTO_FALLBACK`, `REINJECT` used identically across Tasks 1-3 and asserted in Task 5. Harness helpers (`mkstate`/`mktrans`/`mkcard`/`runhook`/`getfm`/`assert`/`summary`) defined once in `lib.sh` (Task 0) and used unchanged. Assembly block shown in full in T1, T2, T3 (final form) — the incremental rewrites are intentional and each shows the complete current state, not a diff.

**Known weakness (stated, not hidden):** Task 4's command-file tests are grep-based content assertions, not behavioral — a future reword of those files could pass the greps while drifting intent. The live round-trip (Task 6) is the real integration check for the command layer, but it is human-run and not part of `all.sh`. This is inherent to testing agent-facing Markdown and is accepted.

**4. GLM first-pass review — adjudicated and folded in (each verified against real files before applying, not adopted on the report's say-so):**
- **B1 (blocker, confirmed):** the shipped `lesson-card.md` template carries inline `# comment` prose on its `tags`/`severity`/`hits` frontmatter lines; the original `card_field` returned them, so a filled card's `severity` became `high  # …` → failed the `case` match → card silently dropped, and `tags` comments leaked into the catalog. **Fixed:** `card_field` now strips trailing `# …` and trims whitespace (Task 2 Step 3). `mkcard` (Task 0) now emits the *commented* shape so every catalog test exercises the strip; L3 gained explicit no-comment-leak assertions. Verified end-to-end (commented card → clean catalog line, malformed/template excluded, ranking intact).
- **B2 (partially confirmed):** GLM claimed `.gitignore` lacks `.repete/` — **false**, it's line 47. The real issue is the stale `.repete/` left on disk from this session's smoke tests. **Fixed:** Task 6 Step 1 now `rm -rf .repete` *before* scaffolding the live mission. No gitignore change needed.
- **B3 (false-green at red step, confirmed):** L2's fallback assertions all passed against the v1 heredoc, so the TDD "verify it fails" step wasn't red for the fallback path. **Fixed:** added an L2 assertion on phrasing distinctive to the inline fallback (`"MISSION goal in .repete/MISSION.md is verifiably TRUE"`) that the v1 heredoc and the new template do *not* contain.
- **B4 (fragile grep, confirmed):** L4's `grep -cE '^  [a-z]-high '` coupled the cap-count to slug names and `%-22s` padding width. **Fixed:** count real catalog rows (`'^  [^ ].*\['`) minus the overflow line. Verified the replacement counts 2.
- **S3 (taken):** constitution is now injected with HTML comments stripped and leading/trailing blanks trimmed (internal blanks preserved), via a portable awk pipeline (no `tac`/`tail -r` — macOS lacks `tac`). Serves §7 "stay short" better than literal "verbatim"; comment noise no longer rides every iteration. L6 gained a comment-strip assertion.
- **S4 (taken):** L8b asserts the catalog is rebuilt fresh each Stop (add a card between two Stops → it appears), locking spec §5's "fresh, not a maintained INDEX.md".
- **S5 (taken):** D1 now anchors on the v1 `<seeded` placeholder being gone + positive no-content-sink phrasing, instead of a fragile negative substring match.
- **N1 (confirmed):** control-flow is **19** assertions, not 20 (the v1 "standing rules appended" assertion was dropped — the protocol moved to a template). All expected-count lines corrected; Task 1 layers count corrected 10→11 (L2 +1 from B3).
- **Declined:** S1 (ERR-trap niceness — low value), S2 (GLM self-withdrew; the literal-replace is correct), N2–N5 (cosmetic or already-correct, e.g. `${CLAUDE_PLUGIN_ROOT}` already used by the v1 scaffold).

All embedded bash that changed (B1 `card_field`+`build_catalog`, B4 grep, S3 constitution pipeline) was dry-run before being written into the plan — outputs verified, not assumed.
