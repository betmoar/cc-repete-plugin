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
