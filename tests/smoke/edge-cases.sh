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
