#!/usr/bin/env bash
# cc-repete statusline segment tests. Run from anywhere: bash tests/test-statusline.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEG="$ROOT/statusline/repete.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ck(){ if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }

# Write a minimal loop.local.md into TMP/.repete/
mkstate(){  # active iter max
  mkdir -p "$TMP/.repete"
  printf -- '---\nactive: %s\niteration: %s\nmax_iterations: %s\n---\n' "$1" "$2" "$3" \
    > "$TMP/.repete/loop.local.md"
}
# The segment resolves the project dir from stdin (.workspace.project_dir),
# matching the Stop hook's CLAUDE_PROJECT_DIR:-$PWD view. Feed it that path and
# also export CLAUDE_PROJECT_DIR so the no-jq fallback resolves to TMP too.
run(){ printf '{"workspace":{"project_dir":"%s"}}' "$TMP" | CLAUDE_PROJECT_DIR="$TMP" bash "$SEG"; }

echo "== Active loop with cap: shows rp[iter/max] =="
mkstate true 3 10
OUT="$(run)"
ck "shows rp[3/10]" '[ "$OUT" = "rp[3/10]" ]'

echo "== Active loop uncapped (max=0): shows rp[iter] =="
mkstate true 7 0
OUT="$(run)"
ck "shows rp[7]" '[ "$OUT" = "rp[7]" ]'

echo "== Non-numeric max: falls back to rp[iter], no error noise =="
mkstate true 4 ""
OUT="$(run 2>/dev/null)"
ck "shows rp[4] when max blank" '[ "$OUT" = "rp[4]" ]'
ERR="$(run 2>&1 >/dev/null)"
ck "no stderr noise when max blank" '[ -z "$ERR" ]'

echo "== Reads project .repete, not CLAUDE_PLUGIN_ROOT (regression guard) =="
# State lives ONLY under the project dir; CLAUDE_PLUGIN_ROOT points elsewhere.
# The pre-fix script read \$CLAUDE_PLUGIN_ROOT/.repete and would emit nothing here.
mkstate true 2 5
OUT="$(printf '{"workspace":{"project_dir":"%s"}}' "$TMP" \
       | CLAUDE_PLUGIN_ROOT="$TMP/nonexistent-plugin-root" CLAUDE_PROJECT_DIR="$TMP" bash "$SEG")"
ck "shows rp[2/5] from project dir" '[ "$OUT" = "rp[2/5]" ]'

echo "== No-jq fallback resolves via CLAUDE_PROJECT_DIR =="
# Empty stdin (no project_dir field) -> must fall back to the env var.
mkstate true 1 0
OUT="$(printf '{}' | CLAUDE_PROJECT_DIR="$TMP" bash "$SEG")"
ck "shows rp[1] via env fallback" '[ "$OUT" = "rp[1]" ]'

echo "== Inactive loop: emits nothing =="
mkstate false 3 10
OUT="$(run)"
ck "empty output when inactive" '[ -z "$OUT" ]'

echo "== Missing state file: emits nothing =="
rm -f "$TMP/.repete/loop.local.md"
OUT="$(run)"
ck "empty output when no state file" '[ -z "$OUT" ]'

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
