#!/usr/bin/env bash
# The full cc-repete check suite — run this before every commit.
# Same checks as CI (.github/workflows/ci.yml); keep the two in sync.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck =="
  shellcheck "$ROOT"/hooks/*.sh "$ROOT"/statusline/*.sh "$ROOT"/tests/*.sh || rc=1
else
  echo "== shellcheck: not installed — lint SKIPPED locally (CI still enforces it) =="
fi

echo "== plugin manifests are valid JSON =="
jq -e . "$ROOT/.claude-plugin/plugin.json" "$ROOT/.claude-plugin/statusline.json" \
        "$ROOT/hooks/hooks.json" >/dev/null || { echo "  FAIL: manifest JSON"; rc=1; }

bash "$ROOT/tests/test-hooks.sh" || rc=1
bash "$ROOT/tests/test-statusline.sh" || rc=1

[ "$rc" -eq 0 ] && echo "ALL SUITES GREEN" || echo "SUITE FAILURES — see above"
exit "$rc"
