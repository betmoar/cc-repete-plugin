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

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
