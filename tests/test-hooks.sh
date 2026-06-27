#!/usr/bin/env bash
# cc-repete hook smoke tests. Run from anywhere: bash tests/test-hooks.sh
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

# Helper: update one frontmatter key in the test state file (mirrors the hook's set_fm).
setstate(){ # key value
  local tmp="$TMP/.repete/loop.local.md.tmp.$$"
  awk -v k="$1" -v v="$2" '
    /^---[[:space:]]*$/ { f++; print; next }
    f==1 && index($0, k":")==1 { print k": " v; next }
    { print }
  ' "$TMP/.repete/loop.local.md" > "$tmp" && mv "$tmp" "$TMP/.repete/loop.local.md"
}

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

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
