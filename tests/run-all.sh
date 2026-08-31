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
# marketplace.json included: it is read from repo HEAD by `/plugin marketplace
# add`, so a malformed edit breaks installs while a suite that skips it stays
# green (2026-08-31 audit F05). Keep this list in sync with ci.yml AND release.yml.
jq -e . "$ROOT/.claude-plugin/plugin.json" "$ROOT/.claude-plugin/statusline.json" \
        "$ROOT/.claude-plugin/marketplace.json" \
        "$ROOT/hooks/hooks.json" >/dev/null || { echo "  FAIL: manifest JSON"; rc=1; }

bash "$ROOT/tests/test-hooks.sh" || rc=1
bash "$ROOT/tests/test-statusline.sh" || rc=1

if command -v node >/dev/null 2>&1; then
  echo "== release gate (scripts/release-gate.mjs) =="
  node --test "$ROOT/tests/test-release-gate.mjs" || rc=1
else
  echo "== release gate: node not installed — SKIPPED locally (CI still enforces it) =="
fi

[ "$rc" -eq 0 ] && echo "ALL SUITES GREEN" || echo "SUITE FAILURES — see above"
exit "$rc"
