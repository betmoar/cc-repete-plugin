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
