#!/usr/bin/env bash
# Regenerate tests/golden-default-reinject.sha after a DELIBERATE change to the
# default-config re-inject (new rule, reworded protocol, reordered layer).
#
# The golden test in test-hooks.sh locks the default re-inject byte-for-byte;
# before this tool existed, updating it meant hand-reconstructing the exact
# fixture + `jq -r .reason | shasum | cut -d" " -f1` pipeline from the test
# source — one wrong detail locks a wrong value forever (2026-08-31 audit F10).
#
# COUPLING: the fixture below must stay byte-identical to the golden block in
# tests/test-hooks.sh (scaffold "" defaults + mktx "did some work" + session
# GOLD). If you change either, change both.
#
# Usage: bash tests/regen-golden.sh          # show old vs new, write only on change
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$ROOT/hooks/stop-hook.sh"
SHA_FILE="$ROOT/tests/golden-default-reinject.sha"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

command -v jq >/dev/null 2>&1 || { echo "regen-golden: jq required" >&2; exit 1; }

# Fixture: mirror of test-hooks.sh scaffold "" (defaults, no flags) + one work turn.
mkdir -p "$TMP/.repete/lessons"
{
  printf -- '---\nactive: true\nphase: 1\niteration: 1\nsession_id: ""\n'
  printf 'max_iterations: 0\ncontext_budget_lines: 0\nlesson_catalog_cap: 8\n'
  printf 'stale_count: 0\nstale_limit: 3\n'
  printf 'mission_goal: "all tests pass"\nstatus: running\nstarted_at: ""\n'
  printf -- '---\n## This loop'"'"'s exit goal\ndo the slice\n'
} > "$TMP/.repete/loop.local.md"
printf -- '---\nslug: foo-trap\ntags: [parser]\nseverity: high\nhits: 2\n---\n**Rule:** x\n' \
  > "$TMP/.repete/lessons/001-foo-trap.md"
printf '{"message":{"role":"assistant","content":[{"type":"text","text":"did some work"}]}}\n' > "$TMP/t.jsonl"

OUT="$(printf '%s' "{\"transcript_path\":\"$TMP/t.jsonl\",\"session_id\":\"GOLD\"}" \
  | CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$H")"
NEW="$(printf '%s' "$OUT" | jq -r .reason | shasum | cut -d" " -f1)"
OLD="$(cat "$SHA_FILE" 2>/dev/null || echo "<none>")"

echo "old golden: $OLD"
echo "new golden: $NEW"
if [ "$NEW" = "$OLD" ]; then
  echo "unchanged — nothing written."
  exit 0
fi
printf '%s\n' "$NEW" > "$SHA_FILE"
echo "written to $SHA_FILE — commit it WITH the change that moved it, and say why in the message."
