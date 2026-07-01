#!/usr/bin/env bash
# cc-repete hook smoke tests. Run from anywhere: bash tests/test-hooks.sh
# shellcheck disable=SC2016,SC2034  # ck() takes each assertion as a literal
# string and evals it, so single quotes are deliberate and $OUT is used there.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$ROOT/hooks/stop-hook.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ck(){ if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }
run(){ printf '%s' "$1" | CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$H"; }

# Build a .repete/loop.local.md with given frontmatter flag lines + a real mission.
# $1 = extra frontmatter lines (newline-separated), e.g. 'lessons_enabled: true'
scaffold(){
  rm -rf "$TMP/.repete"
  mkdir -p "$TMP/.repete/lessons"
  {
    printf -- '---\nactive: true\nphase: 1\niteration: 1\nsession_id: ""\n'
    printf 'max_iterations: 0\ncontext_budget_lines: 0\nlesson_catalog_cap: 8\n'
    printf 'mission_goal: "all tests pass"\nstatus: running\nstarted_at: ""\n'
    [ -n "$1" ] && printf '%s\n' "$1"
    printf -- '---\n## This loop'"'"'s exit goal\ndo the slice\n'
  } > "$TMP/.repete/loop.local.md"
  # a real lesson card so the catalog WOULD have content if enabled
  printf -- '---\nslug: foo-trap\ntags: [parser]\nseverity: high\nhits: 2\n---\n**Rule:** x\n' \
    > "$TMP/.repete/lessons/001-foo-trap.md"
}
# transcript: one assistant text message ($1 = its text)
mktx(){ printf '{"message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$1" > "$TMP/t.jsonl"; }

echo "== Quiet by default: no catalog, no todo/lesson rules =="
scaffold ""                       # no flags -> all default OFF
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "re-injects (decision block)" 'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'
ck "no lessons catalog" '! printf "%s" "$OUT" | jq -r .reason | grep -q "Known lessons"'
ck "no todo-next rule"  '! printf "%s" "$OUT" | jq -r .reason | grep -q "todo-next.md"'
ck "no lesson-card rule" '! printf "%s" "$OUT" | jq -r .reason | grep -q "write a lesson card"'
ck "still carries done sentinel" 'printf "%s" "$OUT" | jq -r .reason | grep -q "<repete-done>"'

echo "== Opt-in restores catalog + rules =="
scaffold $'lessons_enabled: true\ntodo_next_enabled: true'
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "lessons catalog present"  'printf "%s" "$OUT" | jq -r .reason | grep -q "Known lessons"'
ck "todo-next rule present"   'printf "%s" "$OUT" | jq -r .reason | grep -q "todo-next.md"'
ck "lesson-card rule present" 'printf "%s" "$OUT" | jq -r .reason | grep -q "write a lesson card"'

echo "== Garbage flag value -> fail-open to OFF =="
scaffold $'lessons_enabled: yes\ntodo_next_enabled: 1'   # non-"true" -> must be treated as off
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "garbage lessons_enabled stays quiet" '! printf "%s" "$OUT" | jq -r .reason | grep -q "Known lessons"'
ck "garbage todo_next_enabled stays quiet" '! printf "%s" "$OUT" | jq -r .reason | grep -q "todo-next.md"'

echo "== PROTO_FALLBACK still carries the done sentinel (template unreadable) =="
# Point CLAUDE_PLUGIN_ROOT at a dir with no templates/protocol.md so the hook takes
# the inline PROTO_FALLBACK path; it must still inject <repete-done>.
scaffold ""
mktx "did some work"
OUT="$(printf '%s' "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}" \
  | CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$TMP/noplugin" bash "$H")"
ck "fallback carries done sentinel" 'printf "%s" "$OUT" | jq -r .reason | grep -q "<repete-done>"'
ck "fallback + gated still gets checkpoint rule (from RULES_EXTRA)" 'printf "%s" "$OUT" | jq -r .reason | grep -q "<repete-checkpoint>"'

echo "== Autonomous: checkpoint is ignored, loop continues =="
scaffold 'autonomous: true'
mktx "done slice <repete-checkpoint>next: do part 2</repete-checkpoint>"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "autonomous re-injects (block)"      'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'
ck "autonomous writes no transition"    '[ ! -s "$TMP/.repete/transition.md" ]'
ck "autonomous stays running"           'grep -qE "^status: running" "$TMP/.repete/loop.local.md"'

echo "== Gated (default): same checkpoint pauses =="
scaffold ''     # autonomous default false
mktx "done slice <repete-checkpoint>next: do part 2</repete-checkpoint>"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "gated writes transition.md"   '[ -s "$TMP/.repete/transition.md" ]'
ck "gated sets paused-checkpoint" 'grep -qE "^status: paused-checkpoint" "$TMP/.repete/loop.local.md"'

echo "== Autonomous: mission-done still wins =="
scaffold 'autonomous: true'
mktx "<repete-done>all tests pass</repete-done>"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "autonomous done tears loop down" 'grep -qE "^active: false" "$TMP/.repete/loop.local.md"'

echo "== Autonomous + both budgets 0: hook stamps a safety cap (no infinite trap) =="
scaffold 'autonomous: true'   # scaffold defaults max_iterations:0, context_budget_lines:0
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "backstop stamps max_iterations=25" 'grep -qE "^max_iterations: 25" "$TMP/.repete/loop.local.md"'
ck "backstop warns once in systemMessage" 'printf "%s" "$OUT" | jq -r .systemMessage | grep -q "safety max_iterations=25"'
ck "still re-injects this turn (block)"   'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

# The "WITH a cap" / "context budget set" backstop cases live below, after the
# setstate helper — scaffold only appends keys (it can't override the default
# max_iterations:0 / context_budget_lines:0 it already wrote), so those cases
# must mutate the existing key with setstate instead of duplicating it.

# Helper: update one frontmatter key in the test state file (mirrors the hook's set_fm).
setstate(){ # key value
  local tmp="$TMP/.repete/loop.local.md.tmp.$$"
  awk -v k="$1" -v v="$2" '
    /^---[[:space:]]*$/ { f++; print; next }
    f==1 && index($0, k":")==1 { print k": " v; next }
    { print }
  ' "$TMP/.repete/loop.local.md" > "$tmp" && mv "$tmp" "$TMP/.repete/loop.local.md"
}

echo "== Autonomous WITH a cap: backstop does not override it =="
scaffold 'autonomous: true'
setstate max_iterations 5      # mutate the existing key, don't append a dup
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "user cap preserved (5, not 25)" 'grep -qE "^max_iterations: 5" "$TMP/.repete/loop.local.md"'
ck "no backstop warning when capped" '! printf "%s" "$OUT" | jq -r .systemMessage | grep -q "safety max_iterations"'

echo "== Autonomous + context budget set: no cap forced =="
scaffold 'autonomous: true'
setstate context_budget_lines 50
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "context budget counts as a yield (max stays 0)" 'grep -qE "^max_iterations: 0" "$TMP/.repete/loop.local.md"'
ck "no backstop warning when budget set" '! printf "%s" "$OUT" | jq -r .systemMessage | grep -q "safety max_iterations"'

echo "== Session isolation: known session, different Stop session is ignored =="
scaffold ""
setstate session_id '"SESSION_A"'
mktx "did some work"
OUT="$(printf '%s' "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"SESSION_B\"}" \
  | CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$H")"
ck "session mismatch: hook exits silently"  '[ -z "$OUT" ]'
ck "session mismatch: status unchanged"     'grep -qE "^status: running" "$TMP/.repete/loop.local.md"'

echo "== Already-paused states: hook exits 0 immediately =="
for pstate in paused-checkpoint paused-context paused-max; do
  scaffold ""
  setstate status "$pstate"
  mktx "did some work"
  OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
  ck "already-${pstate}: exits silently" '[ -z "$OUT" ]'
done

echo "== paused-max: iteration cap fires and sets correct status =="
scaffold ""
setstate max_iterations 3
setstate iteration 3
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "paused-max: status file updated"          'grep -qE "^status: paused-max" "$TMP/.repete/loop.local.md"'
ck "paused-max: systemMessage names the cap"  'printf "%s" "$OUT" | jq -r .systemMessage | grep -q "max_iterations"'

echo "== repete-done: whitespace-normalized match =="
scaffold ""
mktx "<repete-done>  all tests pass  </repete-done>"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "done normalized: active=false"  'grep -qE "^active: false" "$TMP/.repete/loop.local.md"'
ck "done normalized: status=done"   'grep -qE "^status: done" "$TMP/.repete/loop.local.md"'

echo "== Context budget two-step: pass 1 marks summarizing =="
scaffold ""
setstate context_budget_lines 3
printf '%s\n%s\n%s\n%s\n' \
  '{"message":{"role":"assistant","content":[{"type":"text","text":"a"}]}}' \
  '{"message":{"role":"assistant","content":[{"type":"text","text":"b"}]}}' \
  '{"message":{"role":"assistant","content":[{"type":"text","text":"c"}]}}' \
  '{"message":{"role":"assistant","content":[{"type":"text","text":"d"}]}}' \
  > "$TMP/t.jsonl"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "budget pass1: status=summarizing"          'grep -qE "^status: summarizing" "$TMP/.repete/loop.local.md"'
ck "budget pass1: decision=block"              'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'
ck "budget pass1: reason requests handoff.md"  'printf "%s" "$OUT" | jq -r .reason | grep -q "handoff.md"'
ck "budget pass1: iteration not bumped"        'grep -qE "^iteration: 1$" "$TMP/.repete/loop.local.md"'

echo "== Context budget two-step: pass 2 with filled handoff -> paused-context =="
# State still has status: summarizing and t.jsonl still exceeds budget=3
printf 'Done: merged PR #42\nIn flight: formatter rewrite, half done\nNext: finish formatter pass\nRisks: none\n' \
  > "$TMP/.repete/handoff.md"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "budget pass2 filled: status=paused-context"            'grep -qE "^status: paused-context" "$TMP/.repete/loop.local.md"'
ck "budget pass2 filled: systemMessage confirms snapshot"  'printf "%s" "$OUT" | jq -r .systemMessage | grep -q "handoff snapshot saved"'

echo "== Context budget two-step: pass 2 with empty handoff -> warns =="
scaffold ""
setstate context_budget_lines 3
setstate status summarizing
printf '' > "$TMP/.repete/handoff.md"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "budget pass2 empty: status=paused-context"           'grep -qE "^status: paused-context" "$TMP/.repete/loop.local.md"'
ck "budget pass2 empty: systemMessage warns delta lost"  'printf "%s" "$OUT" | jq -r .systemMessage | grep -q "NOT captured"'

echo "== Stranded summarizing: budget disabled -> recover to running, re-inject =="
scaffold ""
setstate status summarizing
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "stranded: decision=block (loop re-injects)"     'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'
ck "stranded: iteration bumped (normal re-inject)"  'grep -qE "^iteration: 2$" "$TMP/.repete/loop.local.md"'

# ---------------------------------------------------------------------------
# Invariant locks: each block below pins a documented guarantee (the I*/C* tags
# from comments in the hook) or a fixed regression. If one of these fails, a
# guarantee the commands/README/skills promise has been broken — do not delete
# the test to get green; fix the hook.
# ---------------------------------------------------------------------------

echo "== I2: checkpoint + done in the same message -> checkpoint wins (gated) =="
scaffold ""
mktx "<repete-checkpoint>next payload</repete-checkpoint> and <repete-done>all tests pass</repete-done>"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "I2: pauses at checkpoint, not done"  'grep -qE "^status: paused-checkpoint" "$TMP/.repete/loop.local.md"'
ck "I2: loop NOT torn down"              'grep -qE "^active: true" "$TMP/.repete/loop.local.md"'

echo "== I1: a '---' horizontal rule inside the body survives into the re-inject =="
scaffold ""
printf -- 'part A\n\n---\n\npart B after the rule\n' >> "$TMP/.repete/loop.local.md"
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "I1: text before the rule injected" 'printf "%s" "$OUT" | jq -r .reason | grep -q "part A"'
ck "I1: text after the rule injected"  'printf "%s" "$OUT" | jq -r .reason | grep -q "part B after the rule"'

echo "== C1: set_fm never touches body lines that look like frontmatter =="
scaffold ""
printf 'status: bogus-line-in-body\n' >> "$TMP/.repete/loop.local.md"
mktx "done slice <repete-checkpoint>next</repete-checkpoint>"   # forces set_fm status
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "C1: frontmatter status updated"   'grep -qE "^status: paused-checkpoint" "$TMP/.repete/loop.local.md"'
ck "C1: body decoy line untouched"    'grep -qE "^status: bogus-line-in-body" "$TMP/.repete/loop.local.md"'

echo "== C2: session id with '&' '|' '/' is stamped verbatim on first sight =="
scaffold ""   # session_id: ""
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"a&b|c/d\"}")"
ck "C2: special chars persisted literally" 'grep -qF "session_id: \"a&b|c/d\"" "$TMP/.repete/loop.local.md"'

echo "== C3: set_fm appends a key missing from the frontmatter =="
scaffold 'autonomous: true'
awk '!/^max_iterations:/' "$TMP/.repete/loop.local.md" > "$TMP/s" && mv "$TMP/s" "$TMP/.repete/loop.local.md"
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "C3: backstop cap persisted despite missing key" 'grep -qE "^max_iterations: 25" "$TMP/.repete/loop.local.md"'
ck "C3: key landed in frontmatter, not body" 'awk "/^---/{f++} f==1 && /^max_iterations: 25/{found=1} END{exit !found}" "$TMP/.repete/loop.local.md"'
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "C3: no repeat backstop warning once persisted" '! printf "%s" "$OUT" | jq -r .systemMessage | grep -q "safety max_iterations"'

echo "== Malformed transcript line: sentinels still detected (fail-open, never fail-closed) =="
scaffold ""
mktx "<repete-done>all tests pass</repete-done>"
printf '%s\n' '{"truncated garbage no close' >> "$TMP/t.jsonl"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "bad line skipped: done still tears loop down" 'grep -qE "^active: false" "$TMP/.repete/loop.local.md"'

echo "== Sidechain (subagent) sentinel is ignored =="
scaffold ""
{
  printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"main thread work"}]}}'
  printf '%s\n' '{"isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"<repete-done>all tests pass</repete-done>"}]}}'
} > "$TMP/t.jsonl"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "sidechain done does NOT end the loop" 'grep -qE "^active: true" "$TMP/.repete/loop.local.md"'
ck "loop re-injects instead"              'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

echo "== Empty mission_goal: a done sentinel cannot tear the loop down =="
scaffold ""
setstate mission_goal '""'
mktx "<repete-done>all tests pass</repete-done>"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "no goal -> done ignored, loop continues" 'grep -qE "^active: true" "$TMP/.repete/loop.local.md"'

echo "== Terminal statuses with a stale active:true never re-inject =="
for tstate in 'done' 'cancelled'; do
  scaffold ""
  setstate status "$tstate"     # active stays true (failed teardown / hand edit)
  mktx "did some work"
  OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
  ck "status ${tstate} + active true: exits silently" '[ -z "$OUT" ]'
done

echo "== CRLF-edited state file: loop still runs =="
scaffold ""
sed -i 's/$/\r/' "$TMP/.repete/loop.local.md"
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "CRLF state: still re-injects (block)" 'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

echo "== Protocol placeholders are substituted, not injected raw =="
scaffold ""
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "phase/iteration substituted"  'printf "%s" "$OUT" | jq -r .reason | grep -q "iteration 2"'
ck "no raw \${PHASE} token leaks" '! printf "%s" "$OUT" | jq -r .reason | grep -qF "\${PHASE}"'
ck "no raw \${NEXT} token leaks"  '! printf "%s" "$OUT" | jq -r .reason | grep -qF "\${NEXT}"'

echo "== Constitution: comments-only starter is skipped; filled rules injected =="
scaffold ""
cp "$ROOT/templates/constitution.md" "$TMP/.repete/constitution.md"
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "unfilled starter NOT injected" '! printf "%s" "$OUT" | jq -r .reason | grep -q "project invariants"'
printf '<!-- note -->\n- Never push to origin.\n\n- Run tests with make test.\n' > "$TMP/.repete/constitution.md"
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "filled constitution injected"     'printf "%s" "$OUT" | jq -r .reason | grep -q "Never push to origin."'
ck "constitution header present"      'printf "%s" "$OUT" | jq -r .reason | grep -q "project invariants"'
ck "HTML comments stripped"           '! printf "%s" "$OUT" | jq -r .reason | grep -qF "<!-- note -->"'

echo "== Lessons catalog: ranking, inline-comment severity, cap + overflow, robustness =="
scaffold 'lessons_enabled: true'
setstate lesson_catalog_cap 2
rm -f "$TMP/.repete/lessons/001-foo-trap.md"   # scaffold's seed card would skew the ranking fixture
printf -- '---\nslug: low-card\ntags: [a]\nseverity: low\nhits: 9\n---\nbody\n' > "$TMP/.repete/lessons/001-low.md"
printf -- '---\nslug: high-card\ntags: [b]\nseverity: high   # bit hard\nhits: 08\n---\nbody\n' > "$TMP/.repete/lessons/002-high.md"
printf -- '---\nslug: med-card\ntags: [c]\nseverity: medium\nhits: 2\n---\nbody\n' > "$TMP/.repete/lessons/003-med.md"
printf -- '---\ntags: [d]\nseverity: high\n---\nno slug, must be skipped\n' > "$TMP/.repete/lessons/004-garbage.md"
cp "$ROOT/templates/lesson-card.md" "$TMP/.repete/lessons/_TEMPLATE.md"
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
CAT="$(printf '%s' "$OUT" | jq -r .reason | sed -n '/Known lessons/,/more — grep/p')"
ck "high severity ranks first (inline comment stripped)" 'printf "%s\n" "$CAT" | sed -n 2p | grep -q "high-card"'
ck "leading-zero hits parsed as decimal 8"               'printf "%s\n" "$CAT" | sed -n 2p | grep -q "hits:8"'
ck "medium ranks second"                                 'printf "%s\n" "$CAT" | sed -n 3p | grep -q "med-card"'
ck "cap=2: low card not shown"                           '! printf "%s\n" "$CAT" | grep -q "low-card"'
ck "overflow note counts the hidden card"                'printf "%s\n" "$CAT" | grep -q "+1 more"'
ck "slugless card skipped silently"                      '! printf "%s\n" "$CAT" | grep -q "no slug"'
ck "_TEMPLATE.md never listed"                           '! printf "%s\n" "$CAT" | grep -q "short-kebab-slug"'

echo "== Coupling lock: templates/handoff.md headings match the hook's scaffolding-strip list =="
# The pass-2 "was the handoff actually filled?" test strips the template's own
# section headings. If someone renames a heading in templates/handoff.md without
# updating the strip pattern (and the pass-1 re-inject brief) in the hook, an
# unfilled template would count as "filled" — a false 'snapshot saved'.
while IFS= read -r heading; do
  ck "hook knows heading: $heading" "grep -qF \"$heading\" \"$H\""
done < <(grep -E '^## ' "$ROOT/templates/handoff.md" | sed 's/^## //')

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
