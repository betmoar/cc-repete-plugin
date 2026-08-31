#!/usr/bin/env bash
# cc-repete hook smoke tests. Run from anywhere: bash tests/test-hooks.sh
# shellcheck disable=SC2016,SC2034  # ck() takes each assertion as a literal
# string and evals it, so single quotes are deliberate and $OUT is used there.
#
# ASSERTION CONVENTION (issue #17): prefer a `jq -e` predicate over
# `jq -r ... | grep -q ...`. Under pipefail, grep -q exits at the first match and
# jq takes SIGPIPE, so the pipeline status is non-zero and the assertion FAILS
# even though the string was found. Harmless on today's small fixtures, a flake
# waiting to happen on any payload over the ~64KB pipe buffer (a long catalog, a
# big constitution). The jq -e form makes the exit code itself the assertion:
#   good: printf "%s" "$OUT" | jq -e '.reason | test("Known lessons")' >/dev/null
#   bad:  printf "%s" "$OUT" | jq -r .reason | grep -q "Known lessons"
# Note test() takes a REGEX — escape . * [ ] ( ) etc. when matching literals.
# Existing grep-form assertions are migrated opportunistically when touched;
# every NEW assertion uses jq -e.
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
    printf 'stale_count: 0\nstale_limit: 3\n'
    # gauntlet/reference/bar: NOT seeded — absent must default to off/""/"" (the
    # "missing field" behavior is itself under test). Use scaffold 'gauntlet: true'
    # or setstate to turn it on; never append a second key (fm reads the first).
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
for pstate in paused-checkpoint paused-context paused-max paused-stale; do
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

echo "== Stale: mismatched done-claim is counted + fed back, not silent =="
scaffold ""
mktx "<repete-done>everything works great</repete-done>"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "mismatch: loop NOT torn down"     'grep -qE "^active: true" "$TMP/.repete/loop.local.md"'
ck "mismatch: stale_count bumped to 1" 'grep -qE "^stale_count: 1" "$TMP/.repete/loop.local.md"'
ck "mismatch: re-inject explains the rejection" 'printf "%s" "$OUT" | jq -r .reason | grep -q "does NOT match"'
ck "mismatch: decision=block (keep working)"    'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

echo "== Stale: 3rd consecutive mismatched claim yields paused-stale =="
# two mismatches already counted above; third consecutive trips the default limit
mktx "<repete-done>everything works great</repete-done>"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "2nd mismatch: still running" 'grep -qE "^status: running" "$TMP/.repete/loop.local.md"'
mktx "<repete-done>everything works great</repete-done>"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "3rd mismatch: status=paused-stale" 'grep -qE "^status: paused-stale" "$TMP/.repete/loop.local.md"'
ck "3rd mismatch: systemMessage names the mismatch" 'printf "%s" "$OUT" | jq -r .systemMessage | grep -q "mission goal"'
ck "3rd mismatch: no block (yields to human)"      '! printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

echo "== Stale: a plain work turn resets the counter =="
scaffold ""
mktx "<repete-done>nope</repete-done>"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
grep -qE "^stale_count: 1" "$TMP/.repete/loop.local.md"   # precondition: counted
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "work turn resets stale_count to 0" 'grep -qE "^stale_count: 0" "$TMP/.repete/loop.local.md"'
ck "work turn: no stale note in re-inject" '! printf "%s" "$OUT" | jq -r .reason | grep -q "does NOT match"'

echo "== Stale: stale_limit 0 disables the counter entirely =="
scaffold ""
setstate stale_limit 0
for i in 1 2 3 4 5; do
  mktx "<repete-done>nope</repete-done>"
  OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
done
ck "limit 0: still running after 5 mismatches" 'grep -qE "^status: running" "$TMP/.repete/loop.local.md"'
ck "limit 0: counter never written"            '! grep -qE "^stale_count: [1-9]" "$TMP/.repete/loop.local.md"'

echo "== Stale: missing stale_limit field defaults to on (fail toward human) =="
scaffold ""
grep -vE '^stale_limit:' "$TMP/.repete/loop.local.md" > "$TMP/s" && mv "$TMP/s" "$TMP/.repete/loop.local.md"
for i in 1 2 3; do
  mktx "<repete-done>nope</repete-done>"
  OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
done
ck "absent limit: 3rd mismatch yields paused-stale" 'grep -qE "^status: paused-stale" "$TMP/.repete/loop.local.md"'

echo "== Stale: garbage stale_limit value defaults to 3 =="
scaffold ""
setstate stale_limit 'garbage'
mktx "<repete-done>nope</repete-done>"
mktx "<repete-done>nope</repete-done>"
mktx "<repete-done>nope</repete-done>"
for i in 1 2 3; do
  OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
done
ck "garbage limit: behaves as 3 (paused-stale)" 'grep -qE "^status: paused-stale" "$TMP/.repete/loop.local.md"'

echo "== Stale: matching done with a nonzero counter still tears down cleanly =="
scaffold ""
setstate stale_count 2
mktx "<repete-done>all tests pass</repete-done>"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "true done beats a dirty counter" 'grep -qE "^status: done" "$TMP/.repete/loop.local.md"'

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
perl -i -pe 's/\n/\r\n/' "$TMP/.repete/loop.local.md"   # BSD sed -i can't add CR; perl is portable (already a dep)
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

echo "== F11/F12: catalog hardening — tabs and # in card fields =="
scaffold 'lessons_enabled: true'
rm -f "$TMP/.repete/lessons/001-foo-trap.md"
printf -- '---\nslug: tab-card\ntags: [a\tb]\nseverity: high\nhits: 3\n---\nbody\n' > "$TMP/.repete/lessons/010-tab.md"
printf -- '---\nslug: hash-card\ntags: [parser, #123]\nseverity: medium\nhits: 2\n---\nbody\n' > "$TMP/.repete/lessons/011-hash.md"
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
CAT="$(printf '%s' "$OUT" | jq -r .reason | sed -n '/Known lessons/,/more — grep/p')"
ck "F11: tab in tags sanitized, columns intact" 'printf "%s\n" "$CAT" | grep -qE "tab-card +\[a-b\] high +hits:3"'
ck "F12: # in tags preserved (issue refs)"      'printf "%s\n" "$CAT" | grep -qE "hash-card +\[parser,#123\] medium +hits:2"'

echo "== Review: tags-line template comment stripped; # inside brackets kept; slug tab =="
scaffold 'lessons_enabled: true'
rm -f "$TMP/.repete/lessons/001-foo-trap.md"
printf -- '---\nslug: tpl-card\ntags: [jest, esm]   # used to decide which lessons to surface\nseverity: high\nhits: 2\n---\nbody\n' > "$TMP/.repete/lessons/012-tpl.md"
printf -- '---\nslug: sl\tug-tab\ntags: [a]\nseverity: medium\nhits: 1\n---\nbody\n' > "$TMP/.repete/lessons/013-slugtab.md"
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
CAT="$(printf '%s' "$OUT" | jq -r .reason | sed -n '/Known lessons/,/more — grep/p')"
ck "template tags comment stripped, not leaked" '! printf "%s\n" "$CAT" | grep -q "usedtodecide"'
ck "template tags content preserved"            'printf "%s\n" "$CAT" | grep -qE "tpl-card +\[jest,esm\] high +hits:2"'
ck "tab in slug sanitized, columns intact"      'printf "%s\n" "$CAT" | grep -qE "sl-ug-tab +\[a\] medium +hits:1"'

echo "== I2-stale: checkpoint + mismatched done in one message -> checkpoint wins, no count =="
scaffold ""
mktx "<repete-checkpoint>next payload</repete-checkpoint> and <repete-done>nope</repete-done>"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "I2-stale: pauses at checkpoint"        'grep -qE "^status: paused-checkpoint" "$TMP/.repete/loop.local.md"'
ck "I2-stale: mismatch NOT counted"        'grep -qE "^stale_count: 0" "$TMP/.repete/loop.local.md"'

echo "== Stale counting is suppressed while summarizing (budget two-step owns the Stop) =="
scaffold ""
setstate context_budget_lines 3
setstate status summarizing
{
  printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"a"}]}}'
  printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"b"}]}}'
  printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"c"}]}}'
  printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"<repete-done>nope</repete-done>"}]}}'
} > "$TMP/t.jsonl"
printf '' > "$TMP/.repete/handoff.md"   # empty -> pass 2 takes the warns path
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "summarizing mismatch: NOT counted"    'grep -qE "^stale_count: 0" "$TMP/.repete/loop.local.md"'
ck "summarizing mismatch: budget path wins" 'grep -qE "^status: paused-context" "$TMP/.repete/loop.local.md"'

echo "== Autonomous: false done-claims still count (stale yield is a budget-class stop) =="
scaffold 'autonomous: true'
mktx "<repete-done>nope</repete-done>"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "autonomous mismatch counted" 'grep -qE "^stale_count: 1" "$TMP/.repete/loop.local.md"'

echo "== Octal numerics: leading-zero values are DECIMAL, never crash (audit F1) =="
scaffold ""
setstate iteration 08
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "iteration 08 bumps to 9 (no octal crash)" 'grep -qE "^iteration: 9" "$TMP/.repete/loop.local.md"'
ck "decision JSON still emitted (no exit-1 death)" 'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

echo "== Octal max_iterations: cap enforced as decimal =="
scaffold ""
setstate max_iterations 09
setstate iteration 9
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "max 09 caps at 9 -> paused-max" 'grep -qE "^status: paused-max" "$TMP/.repete/loop.local.md"'

echo "== Octal budgets + stale_limit: silent-disable fixed =="
scaffold 'autonomous: true'
setstate max_iterations 00
setstate context_budget_lines 00
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "octal 00 budgets -> backstop stamps 25" 'grep -qE "^max_iterations: 25" "$TMP/.repete/loop.local.md"'
scaffold ""
setstate stale_limit 08
setstate max_iterations 50   # room for 8 mismatch turns (F5 backstop otherwise caps at 25 — fine but noisy)
mktx "<repete-done>nope</repete-done>"
for i in 1 2 3 4 5 6 7 8; do
  OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
  grep -qE "^status: paused-stale" "$TMP/.repete/loop.local.md" && break
done
ck "stale_limit 08 counts to 8 decimal -> paused-stale" 'grep -qE "^status: paused-stale" "$TMP/.repete/loop.local.md"'

echo "== UTF-8 BOM state file: loop stays alive (audit F7) =="
scaffold ""
printf '\xEF\xBB\xBF' | cat - "$TMP/.repete/loop.local.md" > "$TMP/s" && mv "$TMP/s" "$TMP/.repete/loop.local.md"
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "BOM loop still blocks + re-injects" 'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

echo "== F2: mismatched done-claim + budget-cross in one Stop -> feedback survives =="
scaffold ""
setstate context_budget_lines 3
{
  printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"a"}]}}'
  printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"b"}]}}'
  printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"c"}]}}'
  printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"<repete-done>nope</repete-done>"}]}}'
} > "$TMP/t.jsonl"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "F2: stale_count bumped despite budget path" 'grep -qE "^stale_count: 1" "$TMP/.repete/loop.local.md"'
ck "F2: budget pass-1 fires (summarizing)" 'grep -qE "^status: summarizing" "$TMP/.repete/loop.local.md"'
ck "F2: handoff re-inject CARRIES the stale note" 'printf "%s" "$OUT" | jq -r .reason | grep -q "does NOT match"'

# F8 grep-lock: the checkpoint-promote step MUST instruct stale_count reset (prompt-code,
# so the test locks the instruction's presence, not the behavior).
ck "F8: /repete-continue promote resets stale_count (grep-lock)" \
   'grep -q "stale_count.*→.*0" "$ROOT/commands/repete-continue.md"'

echo "== F3: quoted-example sentinel earlier in text must NOT beat the real one =="
scaffold ""
mktx "syntax note: <repete-done>example text</repete-done> — but for real: <repete-done>all tests pass</repete-done>"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "F3: last done capture wins -> mission tears down" 'grep -qE "^status: done" "$TMP/.repete/loop.local.md"'
ck "F3: no stale bump for the quoted example" '! grep -qE "^stale_count: 1" "$TMP/.repete/loop.local.md"'

echo "== F3: two checkpoint blocks -> the LAST payload goes to transition.md =="
scaffold ""
mktx "scratch: <repete-checkpoint>draft payload</repete-checkpoint> ... final: <repete-checkpoint>the real next payload</repete-checkpoint>"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "F3: transition.md carries the LAST payload" 'grep -q "the real next payload" "$TMP/.repete/transition.md"'
ck "F3: draft payload not promoted" '! grep -q "^draft payload$" "$TMP/.repete/transition.md"'

echo "== Toolkit: STALE_NOTE sits between body and catalog (mismatch + lessons on) =="
scaffold 'lessons_enabled: true'
mktx "<repete-done>nope</repete-done>"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
stalepos(){ printf '%s' "$OUT" | jq -r .reason | awk -v m="$1" 'index($0,m){print NR; exit}'; }
SP_BODY="$(stalepos "do the slice")"; SP_NOTE="$(stalepos "does NOT match")"; SP_CAT="$(stalepos "Known lessons")"; SP_PROTO="$(stalepos "repete standing rules")"
ck "stale note ordered: body < note < catalog < protocol" \
   '[ -n "$SP_NOTE" ] && [ "$SP_BODY" -lt "$SP_NOTE" ] && [ "$SP_NOTE" -lt "$SP_CAT" ] && [ "$SP_CAT" -lt "$SP_PROTO" ]'

echo "== Toolkit: octal CTX_BUDGET and CATALOG_CAP fire as decimal =="
scaffold ""
setstate context_budget_lines 03
{
  printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"a"}]}}'
  printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"b"}]}}'
  printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"c"}]}}'
  printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"d"}]}}'
} > "$TMP/t.jsonl"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "octal ctx budget 03 trips at 3 lines -> summarizing" 'grep -qE "^status: summarizing" "$TMP/.repete/loop.local.md"'
scaffold 'lessons_enabled: true'
setstate lesson_catalog_cap 02
rm -f "$TMP/.repete/lessons/001-foo-trap.md"
printf -- '---\nslug: c1\ntags: [a]\nseverity: low\nhits: 1\n---\nb\n' > "$TMP/.repete/lessons/001.md"
printf -- '---\nslug: c2\ntags: [b]\nseverity: high\nhits: 1\n---\nb\n' > "$TMP/.repete/lessons/002.md"
printf -- '---\nslug: c3\ntags: [c]\nseverity: medium\nhits: 1\n---\nb\n' > "$TMP/.repete/lessons/003.md"
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "octal catalog cap 02 caps at 2 (+1 more)" 'printf "%s" "$OUT" | jq -r .reason | grep -q "+1 more"'

echo "== Toolkit: GAUNTLET_FALLBACK carries the critic rule too =="
scaffold $'gauntlet: true\nreference: "r"\nbar: "b"'
mktx "did some work"
OUT="$(printf '%s' "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}" \
  | CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$TMP/noplugin" bash "$H")"
ck "fallback: critic rule present" 'printf "%s" "$OUT" | jq -r .reason | grep -q "critic"'

echo "== F5: GATED loop with both budgets 0 gets the no-escape backstop too =="
scaffold ""    # gated (no autonomous), both budgets 0 from scaffold defaults
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "F5: gated both-0 -> backstop stamps 25" 'grep -qE "^max_iterations: 25" "$TMP/.repete/loop.local.md"'
ck "F5: backstop warning surfaces once" 'printf "%s" "$OUT" | jq -r .systemMessage | grep -q "safety max_iterations"'

echo "== F10: gauntlet on but reference/bar empty -> no gauntlet rules =="
scaffold 'gauntlet: true'
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "F10: no reference -> rules withheld" '! printf "%s" "$OUT" | jq -r .reason | grep -q "gauntlet working rules"'
ck "F10: loop still re-injects normally" 'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

echo "== F10: gauntlet with reference+bar filled -> rules injected =="
scaffold $'gauntlet: true\nreference: "examples/great.md"\nbar: "all parts judged at bar"'
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "F10: reference+bar present -> rules injected" 'printf "%s" "$OUT" | jq -r .reason | grep -q "gauntlet working rules"'

# F4 grep-lock: the paused-context resume branch must address a deferred iteration cap
# (otherwise resume is dead: next Stop fires paused-max with zero work turns).
ck "F4: /repete-continue paused-context handles cap" \
   'grep -q "max_iterations" "$ROOT/commands/repete-continue.md" && awk "/## status: paused-context/,/## status: paused-stale/" "$ROOT/commands/repete-continue.md" | grep -q "iteration.*cap\|cap.*iteration\|max_iterations"'

# F6 grep-lock: /repete must refuse to scaffold over ANY existing .repete/, not just active:true.
ck "F6: /repete guards on existing .repete (any state)" \
   'awk "/already exists/,/repete-status/" "$ROOT/commands/repete.md" | grep -q "done\|cancelled\|terminal\|any"'

echo "== Golden: default-config re-inject is byte-identical across runs =="
# Decline #2 from the review panel, addressed: no golden output existed to prove
# default-config behavior is unchanged. The hook's default-path output is fully
# deterministic (phase/iteration counters, no timestamps), so byte-compare two
# independent runs of the same fixture AND lock the exact content — any future
# change to the default re-inject (new rule, reworded protocol, reordered layer)
# must update this golden deliberately: run `bash tests/regen-golden.sh` (its
# fixture mirrors this block — keep them in sync) and commit the new sha WITH
# the change that moved it.
scaffold ""
mktx "did some work"
G_OUT1="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"GOLD\"}")"
# second run with a FRESH scaffold (same fixture, rebuilt) — proves the output is
# a function of the fixture, not of leftover state
scaffold ""
mktx "did some work"
G_OUT2="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"GOLD\"}")"
ck "golden: two independent runs byte-identical" '[ "$G_OUT1" = "$G_OUT2" ]'
ck "golden: shape is block, single section marker" \
   'printf "%s" "$G_OUT1" | jq -e ".decision==\"block\"" >/dev/null && [ "$(printf "%s" "$G_OUT1" | jq -r .reason | grep -c "^---")" -eq 1 ]'
G_REASON_LINES="$(printf '%s' "$G_OUT1" | jq -r .reason | wc -l | tr -d ' ')"
ck "golden: re-inject line count locked (7)" '[ "$G_REASON_LINES" -eq 7 ]'
G_REASON_SHA="$(printf '%s' "$G_OUT1" | jq -r .reason | shasum | cut -d" " -f1)"
ck "golden: re-inject content hash locked" '[ "$G_REASON_SHA" = "$(cat "$ROOT/tests/golden-default-reinject.sha" 2>/dev/null)" ]'

echo "== Doc-lock: every documented status value exists in all coupled sites =="
# Decline #3 from the review panel, addressed: the couplings table's "grep manually"
# column is now locked for the mechanical part — each status value the docs promise
# must appear in every site the table names for it. A new status that skips a site,
# or a renamed one that leaves a site behind, fails here.
for st in paused-checkpoint paused-context paused-max paused-stale 'done' cancelled summarizing running; do
  ck "doc-lock: '$st' in hook early-exit or status write"  "grep -q '$st' \"$H\""
  ck "doc-lock: '$st' in /repete-status map"               "grep -q '$st' \"$ROOT/commands/repete-status.md\""
done
for st in paused-checkpoint paused-context paused-max paused-stale; do
  ck "doc-lock: '$st' in /repete-continue branches"        "grep -q '$st' \"$ROOT/commands/repete-continue.md\""
done
# sentinel spellings — mirror the ACTUAL contract: <repete-done> lives in the frozen
# protocol core; <repete-checkpoint> is deliberately NOT in protocol.md (the frozen core
# stays quiet in autonomous mode — the rule rides RULES_EXTRA). Both must appear in the
# hook and README; each must appear in at least the running skill + one command.
ck "doc-lock: <repete-done> in protocol + hook + README + running skill + a command" \
   'grep -q "<repete-done>" "$ROOT/templates/protocol.md" && grep -q "<repete-done>" "$H" && grep -q "<repete-done>" "$ROOT/README.md" && grep -q "<repete-done>" "$ROOT/skills/running-repete-loops/SKILL.md" && grep -q "<repete-done>" "$ROOT/commands/repete.md"'
ck "doc-lock: <repete-checkpoint> in hook + README + running skill + repete-continue" \
   'grep -q "<repete-checkpoint>" "$H" && grep -q "<repete-checkpoint>" "$ROOT/README.md" && grep -q "<repete-checkpoint>" "$ROOT/skills/running-repete-loops/SKILL.md" && grep -q "<repete-checkpoint>" "$ROOT/commands/repete-continue.md"'
# frontmatter keys the docs promise
for key in stale_count stale_limit gauntlet reference bar max_iterations context_budget_lines mission_goal; do
  ck "doc-lock: '$key' in template frontmatter + /repete scaffold prose + /repete-status" \
     "grep -q '$key' \"$ROOT/templates/loop.local.md\" && grep -q '$key' \"$ROOT/commands/repete.md\" && grep -q '$key' \"$ROOT/commands/repete-status.md\""
done
# release machinery: the maintainer map must name the gate and the golden regen tool —
# CLAUDE.md drifted behind the release pipeline once already (2026-08-31 audit F09).
ck "doc-lock: CLAUDE.md names the release gate" 'grep -q "release-gate" "$ROOT/CLAUDE.md"'
ck "doc-lock: CLAUDE.md names regen-golden"     'grep -q "regen-golden" "$ROOT/CLAUDE.md"'
ck "doc-lock: golden test block points at regen-golden" 'grep -q "regen-golden" "$ROOT/tests/test-hooks.sh"'


echo "== No perl on PATH: hook degrades to raw-read (fail-open, loop survives) =="
# Minimal PATH without perl; the state read must fall back to raw (BOM unstripped
# — pre-F7 behavior) instead of yielding empty input and silently deactivating.
MINBIN="$(mktemp -d)"
# mv IS in this list: set_fm needs it, and since the A-F01 fix a failed state
# write correctly fails OPEN (no block) — omitting mv here would test "no perl
# AND unwritable state", which is A-F01's fixture, not this one's.
while IFS= read -r t; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$MINBIN/$t"
done < <(printf '%s\n' bash sh cat grep sed awk tr printf head wc jq env ln mv)
rm -f "$MINBIN/perl"
scaffold ""
mktx "did some work"
OUT="$(printf '%s' "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}" \
  | env PATH="$MINBIN" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$H" 2>/dev/null)"
ck "no-perl: normal state file still loops (block)" 'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

# Combined worst case (verify-round): BOM'd file AND no perl. Documented direction:
# pre-F7 behavior — the loop reads inactive and the hook exits silently. Locking it
# prevents a future "fix" from turning this into a crash or a different failure class.
scaffold ""
printf '\xEF\xBB\xBF' | cat - "$TMP/.repete/loop.local.md" > "$TMP/s" && mv "$TMP/s" "$TMP/.repete/loop.local.md"
OUT="$(printf '%s' "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}" \
  | env PATH="$MINBIN" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$H" 2>/dev/null)"
ck "no-perl + BOM: silent exit (pre-F7 inactive), no crash output" '[ -z "$OUT" ]'

echo "== num10 overflow: huge digit-string defaults, never negative =="
scaffold ""
setstate max_iterations 99999999999999999999999999
setstate iteration 1
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "overflow max_iterations -> 0/backstop, cap not silently disabled" 'grep -qE "^max_iterations: (0|25)" "$TMP/.repete/loop.local.md"'
scaffold ""
setstate iteration 99999999999999999999999999
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "overflow iteration -> written back as sane small positive int" \
   'awk "/^---/{f++} f==1 && /^iteration:/{print \$2; exit}" "$TMP/.repete/loop.local.md" | grep -qE "^[0-9]+$" && ! grep -qE "^iteration: -" "$TMP/.repete/loop.local.md"'

echo "== INVARIANT: a mismatched done-claim NEVER tears the loop down =="
scaffold ""
setstate stale_limit 0    # even with the stale detector disabled
mktx "<repete-done>all tests pass</repete-done>"   # this one MATCHES and must tear down
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "matching claim tears down (control)" 'grep -qE "^status: done" "$TMP/.repete/loop.local.md"'
scaffold ""
setstate stale_limit 0
mktx "<repete-done>ALL TESTS PASS</repete-done>"   # case-mismatched: must NEVER be done
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "case-mismatched claim: still active" '! grep -qE "^active: false" "$TMP/.repete/loop.local.md"'
ck "case-mismatched claim: not done"     '! grep -qE "^status: done" "$TMP/.repete/loop.local.md"'

echo "== Gauntlet: default off -> no gauntlet rules in re-inject =="
scaffold ""
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "default off: no parts.md rule" '! printf "%s" "$OUT" | jq -r .reason | grep -q "parts.md"'
ck "default off: still blocks + re-injects" 'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

echo "== Gauntlet: on -> working rules injected =="
scaffold $'gauntlet: true\nreference: "examples/great.md"\nbar: "all parts judged"'
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "on: parts.md rule injected"        'printf "%s" "$OUT" | jq -r .reason | grep -q "parts.md"'
ck "on: critic rule injected"          'printf "%s" "$OUT" | jq -r .reason | grep -q "critic"'
ck "on: final-pass rule injected"      'printf "%s" "$OUT" | jq -r .reason | grep -q "final integration"'
ck "on: rules come after constitution, before protocol" 'printf "%s" "$OUT" | jq -r .reason | grep -q "gauntlet working rules"'
ck "on: still blocks + re-injects (no new exit path)"   'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

echo "== Gauntlet: garbage flag -> off (fail toward default behavior) =="
scaffold 'gauntlet: yes'
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "garbage flag: no gauntlet rules" '! printf "%s" "$OUT" | jq -r .reason | grep -q "gauntlet working rules"'

echo "== Gauntlet: unreadable template -> GAUNTLET_FALLBACK carries the rules =="
scaffold $'gauntlet: true\nreference: "examples/great.md"\nbar: "all parts judged"'
mktx "did some work"
OUT="$(printf '%s' "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}" \
  | CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$TMP/noplugin" bash "$H")"
ck "fallback: parts.md rule present"   'printf "%s" "$OUT" | jq -r .reason | grep -q "parts.md"'
ck "fallback: final-pass rule present" 'printf "%s" "$OUT" | jq -r .reason | grep -q "final integration"'

echo "== Gauntlet: critique.md pointer rides the re-inject =="
scaffold $'gauntlet: true\nreference: "examples/great.md"\nbar: "all parts judged"'
printf 'WINNER: round N-1\nLargest gap: pagination a11y vs reference.\n' > "$TMP/.repete/critique.md"
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "critique first line injected"      'printf "%s" "$OUT" | jq -r .reason | grep -q "WINNER: round N-1"'

echo "== Gauntlet: no critique.md -> no pointer, rest normal =="
scaffold $'gauntlet: true\nreference: "examples/great.md"\nbar: "all parts judged"'
rm -f "$TMP/.repete/critique.md"
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "no critique: no WINNER pointer"  '! printf "%s" "$OUT" | jq -r .reason | grep -q "Last critic verdict"'
ck "no critique: rules still present"  'printf "%s" "$OUT" | jq -r .reason | grep -q "gauntlet working rules"'

echo "== Gauntlet + lessons + constitution compose without clobbering =="
scaffold $'gauntlet: true\nreference: "examples/great.md"\nbar: "all parts judged"\nlessons_enabled: true'
printf '<!-- note -->\n- Never push to origin.\n' > "$TMP/.repete/constitution.md"
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "compose: constitution present" 'printf "%s" "$OUT" | jq -r .reason | grep -q "Never push to origin."'
ck "compose: catalog present"      'printf "%s" "$OUT" | jq -r .reason | grep -q "Known lessons"'
ck "compose: gauntlet present"     'printf "%s" "$OUT" | jq -r .reason | grep -q "gauntlet working rules"'
ck "compose: protocol still LAST"  'printf "%s" "$OUT" | jq -r .reason | grep -q "<repete-done>"'

# Position lock (review finding): the documented assembly order
# body -> [stale note] -> catalog -> constitution -> gauntlet -> protocol LAST
# is load-bearing (CLAUDE.md); assert by LINE ORDER of each layer's marker.
posline(){ printf '%s' "$OUT" | jq -r .reason | awk -v m="$1" 'index($0,m){print NR; exit}'; }
POS_BODY="$(posline "do the slice")"
POS_CAT="$(posline "Known lessons")"
POS_CONST="$(posline "project invariants")"
POS_GAUNT="$(posline "gauntlet working rules")"
POS_PROTO="$(posline "repete standing rules")"
ck "order: body < catalog < constitution < gauntlet < protocol" \
   '[ -n "$POS_BODY" ] && [ -n "$POS_CAT" ] && [ -n "$POS_CONST" ] && [ -n "$POS_GAUNT" ] && [ -n "$POS_PROTO" ] && [ "$POS_BODY" -lt "$POS_CAT" ] && [ "$POS_CAT" -lt "$POS_CONST" ] && [ "$POS_CONST" -lt "$POS_GAUNT" ] && [ "$POS_GAUNT" -lt "$POS_PROTO" ]'

echo "== Coupling lock: templates/gauntlet.md carries the phrases the tests grep =="
while IFS= read -r phrase; do
  ck "gauntlet template has: $phrase" "grep -qF \"$phrase\" \"$ROOT/templates/gauntlet.md\""
done < <(printf '%s\n' 'parts.md' 'critic' 'final integration')

echo "== Coupling lock: templates/handoff.md headings match the hook's scaffolding-strip list =="
# The pass-2 "was the handoff actually filled?" test strips the template's own
# section headings. If someone renames a heading in templates/handoff.md without
# updating the strip pattern (and the pass-1 re-inject brief) in the hook, an
# unfilled template would count as "filled" — a false 'snapshot saved'.
while IFS= read -r heading; do
  ck "hook knows heading: $heading" "grep -qF \"$heading\" \"$H\""
done < <(grep -E '^## ' "$ROOT/templates/handoff.md" | sed 's/^## //')

# ---------------------------------------------------------------------------
# v0.2.1 fixes (issues #7, #10, #11, #12, #16, #18). New assertions use the
# jq -e predicate form documented in the header.
# ---------------------------------------------------------------------------

# Transcript builder for the #18 cases: takes N raw JSONL rows verbatim.
mkrows(){ printf '%s\n' "$@" > "$TMP/t.jsonl"; }
atext(){   printf '{"message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}' "$1"; }
atool(){   printf '%s' '{"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}'; }
uresult(){ printf '%s' '{"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'; }
uprompt(){ printf '{"message":{"role":"user","content":[{"type":"text","text":"%s"}]}}' "$1"; }

echo "== #18: done-claim followed by tool_use entries still tears the loop down =="
scaffold ""
mkrows "$(atext '<repete-done>all tests pass</repete-done>')" "$(atool)" "$(uresult)" "$(atool)"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#18: tool_use tail does not hide the done claim" 'grep -qE "^status: done" "$TMP/.repete/loop.local.md"'
ck "#18: loop torn down (active false)"              'grep -qE "^active: false" "$TMP/.repete/loop.local.md"'

echo "== #18: mismatched claim behind a tool_use tail still counts (stale detector reachable) =="
scaffold ""
mkrows "$(atext '<repete-done>not the goal</repete-done>')" "$(atool)"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#18: mismatch behind tool tail bumps stale_count" 'grep -qE "^stale_count: 1" "$TMP/.repete/loop.local.md"'
ck "#18: mismatch still re-injects with feedback"     'printf "%s" "$OUT" | jq -e ".decision==\"block\" and (.reason | test(\"does NOT match\"))" >/dev/null'

echo "== #18: checkpoint behind a tool_use tail still pauses (gated) =="
scaffold ""
mkrows "$(atext '<repete-checkpoint>next payload here</repete-checkpoint>')" "$(atool)"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#18: checkpoint behind tool tail pauses" 'grep -qE "^status: paused-checkpoint" "$TMP/.repete/loop.local.md"'

echo "== #18: a LATER text entry with no sentinel wins over an earlier claim (same turn) =="
# Guards the other direction: the scan must not reach back past a real text reply.
# The agent claimed done, then kept talking without re-claiming -> no teardown.
scaffold ""
mkrows "$(atext '<repete-done>all tests pass</repete-done>')" "$(atext 'actually wait, one more thing')"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#18: later text-bearing entry wins -> no teardown" 'grep -qE "^active: true" "$TMP/.repete/loop.local.md"'
ck "#18: loop re-injects instead"                      'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

echo "== #18: turn boundary — a spent sentinel from a PREVIOUS turn is not re-fired =="
# A real user prompt starts a new turn. The current turn has no text at all
# (tool_use only), so the scan must yield "" rather than reaching back.
scaffold ""
mkrows "$(atext '<repete-done>all tests pass</repete-done>')" "$(uprompt 'keep going')" "$(atool)"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#18: previous-turn done not re-fired" 'grep -qE "^active: true" "$TMP/.repete/loop.local.md"'
ck "#18: turn-bounded scan re-injects"    'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

echo "== #18: tool_result rows do NOT start a new turn (claim before them still seen) =="
scaffold ""
mkrows "$(atext '<repete-done>all tests pass</repete-done>')" "$(uresult)" "$(atool)"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#18: tool_result is not a turn boundary" 'grep -qE "^status: done" "$TMP/.repete/loop.local.md"'

echo "== #18: a malformed text block does not blank the whole scan (fail-closed guard) =="
# A non-string .text made join() raise, and a jq runtime error aborts the ENTIRE
# program -> LAST_OUTPUT="" -> every sentinel invisible. The old `| last` code
# only ever touched one entry; this program walks many, so it has strictly more
# rows to trip over. `.text | strings` drops the bad block instead.
scaffold ""
mkrows '{"message":{"role":"assistant","content":[{"type":"text","text":{"nested":"object"}}]}}' \
       "$(atext '<repete-done>all tests pass</repete-done>')"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#18: malformed text block skipped, later sentinel still seen" 'grep -qE "^status: done" "$TMP/.repete/loop.local.md"'
# ...and when the malformed block is in the LAST entry, the scan must fall back to
# the previous text entry rather than returning nothing at all.
scaffold ""
mkrows "$(atext '<repete-done>all tests pass</repete-done>')" \
       '{"message":{"role":"assistant","content":[{"type":"text","text":42}]}}'
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#18: malformed LAST block does not blind the scan" 'grep -qE "^status: done" "$TMP/.repete/loop.local.md"'

echo "== #18: a user row mixing tool_result WITH real text DOES open a turn =="
# Observed user-row shapes across 75 real transcripts: tool_result / string / text /
# image+text. A row carrying a tool_result AND human text is a genuine new
# instruction, so it must bound the turn — otherwise a sentinel from before it
# leaks into this turn and re-fires.
scaffold ""
mkrows "$(atext '<repete-done>all tests pass</repete-done>')" \
       '{"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"},{"type":"text","text":"actually, do this instead"}]}}' \
       "$(atool)"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#18: mixed user row bounds the turn (spent claim not re-fired)" 'grep -qE "^active: true" "$TMP/.repete/loop.local.md"'

echo "== #18: an image+text user row opens a turn =="
scaffold ""
mkrows "$(atext '<repete-done>all tests pass</repete-done>')" \
       '{"message":{"role":"user","content":[{"type":"image","source":{}},{"type":"text","text":"look at this"}]}}' \
       "$(atool)"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#18: image+text user row bounds the turn" 'grep -qE "^active: true" "$TMP/.repete/loop.local.md"'

echo "== #18: a SIDECHAIN user row must not become the turn boundary =="
# A subagent's prompt is role:user + isSidechain. If it bounded the turn, every
# main-thread sentinel emitted before a subagent launch would go invisible.
scaffold ""
mkrows "$(uprompt 'real prompt')" \
       "$(atext '<repete-done>all tests pass</repete-done>')" \
       '{"isSidechain":true,"message":{"role":"user","content":"subagent prompt"}}' \
       "$(atool)"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#18: sidechain user row is not a boundary" 'grep -qE "^status: done" "$TMP/.repete/loop.local.md"'

echo "== #18: no user row at all -> scan everything (pre-existing scope) =="
scaffold ""
mkrows "$(atext '<repete-done>all tests pass</repete-done>')" "$(atool)"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#18: turn_start=-1 slices from 0, sentinel found" 'grep -qE "^status: done" "$TMP/.repete/loop.local.md"'

echo "== #18: whitespace-only final text falls back to the prior text entry =="
scaffold ""
mkrows "$(atext '<repete-done>all tests pass</repete-done>')" "$(atext '   ')"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#18: whitespace-only entry skipped" 'grep -qE "^status: done" "$TMP/.repete/loop.local.md"'

echo "== #18: sidechain text still ignored under the new scan =="
scaffold ""
mkrows "$(atext 'main thread work')" \
       '{"isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"<repete-done>all tests pass</repete-done>"}]}}' \
       "$(atool)"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#18: sidechain done still ignored" 'grep -qE "^active: true" "$TMP/.repete/loop.local.md"'

echo "== #10: set_fm writes a value containing a literal backslash unchanged =="
scaffold ""
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"a\\\\nb\\\\tc\"}")"
ck "#10: backslashes survive verbatim (no awk escape processing)" \
   'grep -qF "session_id: \"a\\nb\\tc\"" "$TMP/.repete/loop.local.md"'
ck "#10: loop still re-injects after the write" 'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

echo "== #11: state file with no closing fence -> key still lands, no re-warn =="
scaffold 'autonomous: true'
# Strip the CLOSING fence only (keep the opener), and drop max_iterations so the
# backstop must APPEND it: the exact shape that used to no-op forever.
awk '!/^max_iterations:/' "$TMP/.repete/loop.local.md" > "$TMP/s" && mv "$TMP/s" "$TMP/.repete/loop.local.md"
awk 'BEGIN{f=0} /^---[[:space:]]*$/{f++; if(f==2) next} {print}' "$TMP/.repete/loop.local.md" > "$TMP/s" \
  && mv "$TMP/s" "$TMP/.repete/loop.local.md"
ck "#11: fixture really has no closing fence" '[ "$(grep -cE "^---[[:space:]]*$" "$TMP/.repete/loop.local.md")" -eq 1 ]'
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#11: backstop cap persisted despite missing fence" 'grep -qE "^max_iterations: 25" "$TMP/.repete/loop.local.md"'
ck "#11: fence repaired so the block is parseable"     '[ "$(grep -cE "^---[[:space:]]*$" "$TMP/.repete/loop.local.md")" -eq 2 ]'
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#11: second Stop does not re-warn" '! printf "%s" "$OUT" | jq -e ".systemMessage | test(\"safety max_iterations\")" >/dev/null'
# The repair appends at EOF, which is the only place it CAN append: with no closing
# fence, awk's f==1 covers the rest of the file and nothing distinguishes a trailing
# key from body prose. Lock that it is non-destructive — the body text must still be
# in the file afterwards. (It is not INJECTED, because PAYLOAD_BODY reads after the
# second fence and a fenceless file never had one — same on the pre-v0.2.1 hook.
# Repairing a hand-broken file's frontmatter/body split is out of scope; bounding
# future reads is the point.)
ck "#11: repair is non-destructive — body text survives in the file" \
   'grep -q "do the slice" "$TMP/.repete/loop.local.md"'

echo "== #12: bare 'paused' is not an early-exit status (dead vestige removed) =="
scaffold ""
setstate status paused
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#12: bare paused does not silently exit" '[ -n "$OUT" ]'
ck "#12: unknown status re-injects (treated as running)" 'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'

echo "== #7/#16: no jq on PATH -> exactly one warning, then silence, state untouched =="
NOJQBIN="$(mktemp -d)"
while IFS= read -r t; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOJQBIN/$t"
done < <(printf '%s\n' bash sh cat grep sed awk tr printf head wc env ln perl)
rm -f "$NOJQBIN/jq"
scaffold ""
mktx "did some work"
BEFORE="$(cat "$TMP/.repete/loop.local.md")"
NOJQ1="$(printf '%s' "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}" \
  | env PATH="$NOJQBIN" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$H" 2>/dev/null)"
NOJQ_RC=$?
ck "#7: no-jq exits 0 (fail open)"            '[ "$NOJQ_RC" -eq 0 ]'
ck "#7: first no-jq Stop warns"               'printf "%s" "$NOJQ1" | jq -e ".systemMessage | test(\"jq is not on PATH\")" >/dev/null'
ck "#7: warning is NOT a block decision"      '! printf "%s" "$NOJQ1" | jq -e "has(\"decision\")" >/dev/null'
ck "#7: marker file written"                  '[ -f "$TMP/.repete/.warned-nojq" ]'
NOJQ2="$(printf '%s' "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}" \
  | env PATH="$NOJQBIN" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$H" 2>/dev/null)"
ck "#16: second no-jq Stop is silent (warn once)" '[ -z "$NOJQ2" ]'
ck "#16: no-jq leaves state byte-identical"      '[ "$BEFORE" = "$(cat "$TMP/.repete/loop.local.md")" ]'
# An inactive loop must stay quiet even on the first no-jq Stop.
scaffold ""
setstate active false
NOJQ3="$(printf '%s' "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}" \
  | env PATH="$NOJQBIN" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$H" 2>/dev/null)"
ck "#7: inactive loop + no jq stays silent" '[ -z "$NOJQ3" ]'
ck "#7: inactive loop writes no marker"     '[ ! -f "$TMP/.repete/.warned-nojq" ]'
# The active-check must read FRONTMATTER only (C1): a body line quoting the schema
# is prose, not state. A bare grep matched it and warned about a finished loop.
scaffold ""
setstate active false
setstate status 'done'   # quoted: bare `done` reads as the loop keyword (SC1010)
printf 'the schema line looks like this:\nactive: true\n' >> "$TMP/.repete/loop.local.md"
NOJQ4="$(printf '%s' "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}" \
  | env PATH="$NOJQBIN" CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$H" 2>/dev/null)"
ck "#7: body decoy 'active: true' does not trigger the warning" '[ -z "$NOJQ4" ]'
ck "#7: body decoy writes no marker"                            '[ ! -f "$TMP/.repete/.warned-nojq" ]'

echo "== #16: stranded summarizing re-applies the cap on the SAME Stop =="
# status summarizing + no longer over budget + iteration already at the cap:
# the max-iterations yield was skipped by the summarizing guard, so the recovery
# path must re-apply it now — not one wasted cycle later.
scaffold ""
setstate status summarizing
setstate max_iterations 3
setstate iteration 3
setstate context_budget_lines 10000   # far above the fixture: budget path cannot fire
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#16: stranded+at-cap yields paused-max"      'grep -qE "^status: paused-max" "$TMP/.repete/loop.local.md"'
ck "#16: no re-inject on that Stop"              '! printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'
ck "#16: iteration NOT bumped past the cap"      'grep -qE "^iteration: 3$" "$TMP/.repete/loop.local.md"'
ck "#16: systemMessage names the cap"            'printf "%s" "$OUT" | jq -e ".systemMessage | test(\"max_iterations\")" >/dev/null'

echo "== #16: transition.md is written verbatim and truncated first =="
scaffold ""
printf 'STALE PAYLOAD FROM AN EARLIER LOOP\nsecond line\nthird line\n' > "$TMP/.repete/transition.md"
mktx "<repete-checkpoint>line one\\nline two with # and \$dollar\\nline three</repete-checkpoint>"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "#16: payload written verbatim (all lines)" \
   '[ "$(cat "$TMP/.repete/transition.md")" = "$(printf "line one\nline two with # and \$dollar\nline three")" ]'
ck "#16: prior content truncated, not appended" '! grep -q "STALE PAYLOAD" "$TMP/.repete/transition.md"'

echo "== #16: doc-lock — bare 'paused' gone from the hook early-exit case =="
# Extract the early-exit case arm and assert every alternative is a known status.
# A bare 'paused' (or any newly-invented value) fails here.
EXIT_ARM="$(grep -E '^[[:space:]]*paused-checkpoint\|' "$H" | head -1 | sed 's/).*//' | tr -d '[:space:]')"
ck "#16: early-exit arm found" '[ -n "$EXIT_ARM" ]'
ck "#16: early-exit arm is exactly the documented status set" \
   '[ "$EXIT_ARM" = "paused-checkpoint|paused-context|paused-max|paused-stale|done|cancelled" ]'

# ---------------------------------------------------------------------------
# 2026-08-31 audit fixes (this audit's F01–F04, F08 — NOT the 2026-08-16 F1–F14
# cited elsewhere in comments). Each block locks a reproduced defect.
# ---------------------------------------------------------------------------

echo "== A-F04: trailing space after a numeric value is the user's value, not malformed =="
scaffold ""
setstate max_iterations '5 '     # invisible trailing space from a hand edit
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "A-F04: cap 5 kept — backstop does NOT overwrite with 25" 'grep -qE "^max_iterations: 5" "$TMP/.repete/loop.local.md" && ! grep -qE "^max_iterations: 25" "$TMP/.repete/loop.local.md"'
ck "A-F04: no safety-cap warning for a real cap" '! printf "%s" "$OUT" | jq -e ".systemMessage | test(\"safety max_iterations\")" >/dev/null'
setstate max_iterations '5 '
setstate iteration 5
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "A-F04: trailing-space cap still ENFORCED (paused-max at 5)" 'grep -qE "^status: paused-max" "$TMP/.repete/loop.local.md"'

echo "== A-F02: BOM'd state file keeps its payload BODY in the re-inject =="
scaffold ""
printf '\xEF\xBB\xBF' | cat - "$TMP/.repete/loop.local.md" > "$TMP/s" && mv "$TMP/s" "$TMP/.repete/loop.local.md"
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "A-F02: BOM body rides the re-inject (not just decision=block)" 'printf "%s" "$OUT" | jq -e ".reason | test(\"do the slice\")" >/dev/null'

echo "== A-F03: a sentinel in an EARLIER same-turn text entry does not reset the stale counter =="
scaffold ""
setstate stale_count 2
mkrows "$(uprompt 'go')" "$(atext '<repete-done>not the goal</repete-done>')" "$(atext 'summary of the work')"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "A-F03: earlier-entry mismatch is NEUTRAL — counter neither reset nor bumped" 'grep -qE "^stale_count: 2" "$TMP/.repete/loop.local.md"'
ck "A-F03: neutral turn still re-injects (block)" 'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'
ck "A-F03: un-counted claim gets no mismatch note" '! printf "%s" "$OUT" | jq -e ".reason | test(\"does NOT match\")" >/dev/null'
# ...and the deliberate v0.2.1 half stays locked: a MATCHING claim behind a later
# text entry still does not tear the loop down (last text entry wins).
scaffold ""
mkrows "$(uprompt 'go')" "$(atext '<repete-done>all tests pass</repete-done>')" "$(atext 'wrapping up now')"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "A-F03: matching claim behind trailing text still no teardown (locked)" 'grep -qE "^active: true" "$TMP/.repete/loop.local.md"'
ck "A-F03: matching-claim turn does not touch the counter" 'grep -qE "^stale_count: 0" "$TMP/.repete/loop.local.md"'
# a plain work turn (no sentinel anywhere) still resets — the pre-existing rule
scaffold ""
setstate stale_count 2
mkrows "$(uprompt 'go')" "$(atext 'plain work, no claims')"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
ck "A-F03: plain work turn still resets the counter" 'grep -qE "^stale_count: 0" "$TMP/.repete/loop.local.md"'

echo "== A-F08: >18-digit lesson hits falls to 1, never wraps negative =="
scaffold 'lessons_enabled: true'
rm -f "$TMP/.repete/lessons/001-foo-trap.md"
printf -- '---\nslug: huge-hits\ntags: [a]\nseverity: high\nhits: 99999999999999999999999999\n---\nb\n' > "$TMP/.repete/lessons/001.md"
printf -- '---\nslug: normal-hits\ntags: [b]\nseverity: high\nhits: 5\n---\nb\n' > "$TMP/.repete/lessons/002.md"
mktx "did some work"
OUT="$(run "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"S1\"}")"
A_CAT="$(printf '%s' "$OUT" | jq -r .reason | sed -n '/Known lessons/,/repete standing rules/p')"
ck "A-F08: overflow hits renders as its default (hits:1), not negative" 'printf "%s\n" "$A_CAT" | grep -q "huge-hits.*hits:1" && ! printf "%s\n" "$A_CAT" | grep -q "hits:-"'
ck "A-F08: sane card outranks the overflow card" '[ "$(printf "%s\n" "$A_CAT" | awk "/normal-hits/{print NR}")" -lt "$(printf "%s\n" "$A_CAT" | awk "/huge-hits/{print NR}")" ]'

echo "== A-F01: unwritable .repete/ fails OPEN — the Stop is never blocked =="
# The trap: with state unwritable, pass-1 re-fires forever (status never
# advances, iteration never bumps, no budget can fire) — reproduced pre-fix.
# Root cannot be write-blocked by chmod, so as root run the hook as nobody via
# runuser; skip only when neither route exists (and say so — no silent green).
RO_MODE=""
if [ "$(id -u)" -ne 0 ]; then
  RO_MODE=direct
elif command -v runuser >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
  RO_MODE=runuser
fi
if [ -n "$RO_MODE" ]; then
  RO_DIR="$(mktemp -d)"
  mkdir -p "$RO_DIR/.repete"
  scaffold ""   # build a clean default state, then copy it into the RO fixture
  cp "$TMP/.repete/loop.local.md" "$RO_DIR/.repete/loop.local.md"
  mktx "did some work"; cp "$TMP/t.jsonl" "$RO_DIR/t.jsonl"
  chmod 755 "$RO_DIR"; chmod 644 "$RO_DIR/.repete/loop.local.md" "$RO_DIR/t.jsonl"
  chmod 555 "$RO_DIR/.repete"
  ro_run(){ # input
    if [ "$RO_MODE" = direct ]; then
      printf '%s' "$1" | CLAUDE_PROJECT_DIR="$RO_DIR" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$H" 2>/dev/null
    else
      printf '%s' "$1" | runuser -u nobody -- env CLAUDE_PROJECT_DIR="$RO_DIR" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$H" 2>/dev/null
    fi
  }
  OUT="$(ro_run "{\"transcript_path\":\"$RO_DIR/t.jsonl\",\"session_id\":\"S1\"}")"
  ck "A-F01: re-inject path with unwritable state does NOT block" '! printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'
  ck "A-F01: fail-open warning names the write problem" 'printf "%s" "$OUT" | jq -e ".systemMessage | test(\"cannot write\")" >/dev/null'
  # pass-1 of the context two-step must ALSO bail open, not re-fire forever
  chmod 755 "$RO_DIR/.repete"
  awk '{sub(/^context_budget_lines: 0/, "context_budget_lines: 1"); print}' "$RO_DIR/.repete/loop.local.md" > "$RO_DIR/s" \
    && mv "$RO_DIR/s" "$RO_DIR/.repete/loop.local.md"
  chmod 644 "$RO_DIR/.repete/loop.local.md"; chmod 555 "$RO_DIR/.repete"
  printf '%s\n%s\n' \
    '{"message":{"role":"assistant","content":[{"type":"text","text":"a"}]}}' \
    '{"message":{"role":"assistant","content":[{"type":"text","text":"b"}]}}' > "$RO_DIR/t.jsonl.2"
  chmod 644 "$RO_DIR/t.jsonl.2" 2>/dev/null || true
  OUT="$(ro_run "{\"transcript_path\":\"$RO_DIR/t.jsonl.2\",\"session_id\":\"S1\"}")"
  ck "A-F01: budget pass-1 with unwritable state does NOT block" '! printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'
  ck "A-F01: pass-1 fail-open also warns" 'printf "%s" "$OUT" | jq -e ".systemMessage | test(\"cannot write\")" >/dev/null'
  chmod -R 755 "$RO_DIR"; rm -rf "$RO_DIR"
else
  echo "  SKIP: A-F01 read-only-state tests (root without runuser/nobody — cannot simulate an unwritable dir)"
fi

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
