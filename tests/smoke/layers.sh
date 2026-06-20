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
  END{exit !(b>0 && c>0 && k>0 && p>0 && b<c && c<k && k<p)}'; assert "all four layers present AND ordered brief<catalog<constitution<protocol" $?
echo "$OUT" | jq -e '.reason | contains("001-trap")' >/dev/null 2>&1; assert "catalog card present in full stack" $?
echo "$OUT" | jq -e '.reason | contains("do the thing") | not' >/dev/null 2>&1; assert "no card body leaked in full stack" $?

echo "== L10: octal-looking hits (08/09) do not crash the arithmetic or garble the row (B1) =="
D="$ROOT/l10"; mkstate "$D" running true 1 0 0 '"g"' '"s"'
mkcard "$D" "001-octal" "build" high 09
mkcard "$D" "002-normal" "x" high 8
mktrans "$D/tr.jsonl" "working"
# capture stderr too — an octal arithmetic error would print "value too great for base"
ERROUT="$(CLAUDE_PROJECT_DIR="$D" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash -c 'printf "%s" "$0" | bash "$1"' \
  "$(jq -nc --arg tp "$D/tr.jsonl" --arg sid "s" '{transcript_path:$tp,session_id:$sid}')" "$HOOK" 2>&1 1>/dev/null)"
[[ -z "$ERROUT" ]]; assert "no arithmetic error on stderr for hits:09" $?
runhook "$D" "$D/tr.jsonl" "s"
echo "$OUT" | jq -e '.reason | contains("001-octal")' >/dev/null 2>&1; assert "octal-hits card present (not dropped)" $?
echo "$OUT" | jq -e '.reason | contains("hits:9")' >/dev/null 2>&1; assert "hits:09 rendered as decimal 9" $?
# 001-octal (hits 9) must outrank 002-normal (hits 8) within same severity
echo "$OUT" | jq -r '.reason' | awk '/001-octal/{a=NR} /002-normal/{b=NR} END{exit !(a>0 && b>0 && a<b)}'; assert "hits 9 ranks above hits 8 (numeric, not string)" $?

echo "== L11: a tag containing '#' (c#/f#) survives the comment-strip (N1) =="
D="$ROOT/l11"; mkstate "$D" running true 1 0 0 '"g"' '"s"'
mkcard "$D" "001-csharp" "c#" high 1
mktrans "$D/tr.jsonl" "working"
runhook "$D" "$D/tr.jsonl" "s"
echo "$OUT" | jq -e '.reason | contains("c#")' >/dev/null 2>&1; assert "c# tag not truncated by comment-strip" $?

echo "== L12: lesson_catalog_cap: 0 means uncapped, no overflow note (S2) =="
D="$ROOT/l12"; mkstate "$D" running true 1 0 0 '"g"' '"s"'
perl -0777 -pi -e 's/lesson_catalog_cap: 8/lesson_catalog_cap: 0/' "$D/.repete/loop.local.md"
for n in 1 2 3 4 5 6 7 8 9 10; do mkcard "$D" "card-$n" "t" high "$n"; done
mktrans "$D/tr.jsonl" "working"
runhook "$D" "$D/tr.jsonl" "s"
[[ "$(echo "$OUT" | jq -r '.reason' | grep -cE '^  card-[0-9]+ ')" -eq 10 ]]; assert "cap=0 shows all 10 cards" $?
echo "$OUT" | jq -e '.reason | contains("more —") | not' >/dev/null 2>&1; assert "cap=0 emits no overflow note" $?

summary
