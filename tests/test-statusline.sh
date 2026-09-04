#!/usr/bin/env bash
# cc-repete statusline segment tests. Run from anywhere: bash tests/test-statusline.sh
# shellcheck disable=SC2016,SC2034  # ck() takes each assertion as a literal
# string and evals it, so single quotes are deliberate and $OUT is used there.
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

echo "== Body lines that look like frontmatter keys are ignored =="
# Only the FIRST frontmatter block is state; prose in the body ("active: false",
# "iteration: 99") must not be parsed. The pre-fix whole-file scan captured
# multi-line garbage here and the segment went blank on an active loop.
mkstate true 3 10
printf 'note: when done set\nactive: false\niteration: 99\n' >> "$TMP/.repete/loop.local.md"
OUT="$(run)"
ck "shows rp[3/10] despite body decoys" '[ "$OUT" = "rp[3/10]" ]'

echo "== CRLF-edited state file still renders =="
mkstate true 4 8
perl -i -pe 's/\n/\r\n/' "$TMP/.repete/loop.local.md"   # BSD sed -i can't add CR; perl is portable (already a dep)
OUT="$(run)"
ck "shows rp[4/8] with CRLF endings" '[ "$OUT" = "rp[4/8]" ]'

echo "== Octal leading-zero max: treated as DECIMAL, cap still shown (audit F1) =="
mkstate true 3 09
OUT="$(run 2>/dev/null)"
ck "shows rp[3/9], not octal-error fallback rp[3]" '[ "$OUT" = "rp[3/9]" ]'
mkstate true 3 08
OUT="$(run 2>/dev/null)"
ck "shows rp[3/8] for 08 too" '[ "$OUT" = "rp[3/8]" ]'
mkstate true 3 011
OUT="$(run 2>/dev/null)"
ck "shows rp[3/11] for 011 (not 9)" '[ "$OUT" = "rp[3/11]" ]'

echo "== Quoted values: parity with the hook's fm() (audit F9) =="
mkstate true 3 10
# perl -i (not sed -i ''): BSD/GNU-portable, same approach as the CRLF block above
perl -i -pe 's/^active: true/active: "true"/; s/^iteration: 3/iteration: "3"/; s/^max_iterations: 10/max_iterations: "10"/' "$TMP/.repete/loop.local.md"
OUT="$(run)"
ck "quoted active/iter/max still render rp[3/10]" '[ "$OUT" = "rp[3/10]" ]'

echo "== #30: asymmetric quote reads INACTIVE — parity with fm(), not per-end strips =="
# fmv() used sub(/^"/) + sub(/"$/) independently, so active: true" (and "true)
# rendered as a live segment while the hook's fm() had exited the loop. Quotes
# must strip as a both-ends pair, matching fm() and the no-jq awk (#30).
for V in 'true"' '"true'; do
  mkstate true 3 10
  perl -i -pe "s/^active: true/active: $V/" "$TMP/.repete/loop.local.md"
  OUT="$(run 2>/dev/null)"
  ck "#30: active: $V renders nothing (agrees with fm())" '[ -z "$OUT" ]'
done

echo "== Status differentiation: paused renders distinct from running (audit F14) =="
mkstate true 3 10
for st in paused-checkpoint paused-context paused-max paused-stale; do
  # inject a status key into the frontmatter (mkstate doesn't carry it)
  awk -v s="$st" 'NR==2{print "status: " s} {print}' "$TMP/.repete/loop.local.md" > "$TMP/s" && mv "$TMP/s" "$TMP/.repete/loop.local.md"
  OUT="$(run)"
  ck "status $st renders a pause marker" 'printf "%s" "$OUT" | grep -q "·"'
done
# transient summarizing renders PLAIN (no pause marker): it is a normal in-flight
# turn, not a wait-on-human state
awk 'NR==2{print "status: summarizing"} {print}' "$TMP/.repete/loop.local.md" > "$TMP/s" && mv "$TMP/s" "$TMP/.repete/loop.local.md"
OUT="$(run)"
ck "status summarizing renders plain (transient)" '[ "$OUT" = "rp[3/10]" ]'
mkstate true 3 10
awk 'NR==2{print "status: running"} {print}' "$TMP/.repete/loop.local.md" > "$TMP/s" && mv "$TMP/s" "$TMP/.repete/loop.local.md"
OUT="$(run)"
ck "status running renders plain rp[3/10]" '[ "$OUT" = "rp[3/10]" ]'

echo "== UTF-8 BOM state file: loop still renders (audit F7) =="
mkstate true 5 10
printf '\xEF\xBB\xBF' | cat - "$TMP/.repete/loop.local.md" > "$TMP/s" && mv "$TMP/s" "$TMP/.repete/loop.local.md"
OUT="$(run)"
ck "BOM file still renders rp[5/10]" '[ "$OUT" = "rp[5/10]" ]'

echo "== No perl on PATH: normal state still renders (fail-open) =="
MINBIN="$(mktemp -d)"
while IFS= read -r t; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$MINBIN/$t"
done < <(printf '%s\n' bash sh cat grep sed awk tr printf env ln)
rm -f "$MINBIN/perl"
mkstate true 5 10
OUT="$(printf '{"workspace":{"project_dir":"%s"}}' "$TMP" \
  | env PATH="$MINBIN" CLAUDE_PROJECT_DIR="$TMP" bash "$SEG" 2>/dev/null)"
ck "no-perl: renders rp[5/10] via raw read" '[ "$OUT" = "rp[5/10]" ]'

echo "== num10 overflow: huge max renders as uncapped, never wraps negative =="
mkstate true 3 99999999999999999999999999
OUT="$(run 2>/dev/null)"
ck "overflow max -> rp[3] uncapped (default 0), not garbage" '[ "$OUT" = "rp[3]" ]'

echo "== Quoted status value still renders its pause marker (F14 + quote parity) =="
mkstate true 3 10
perl -i -pe 's/^iteration: 3/iteration: "3"\nstatus: "paused-stale"/' "$TMP/.repete/loop.local.md"
OUT="$(run)"
ck "quoted status paused-stale renders marker" 'printf "%s" "$OUT" | grep -q "stale"'

echo "== A-F04 (2026-08-31 audit): trailing space after max renders the cap, parity with hook fm() =="
mkstate true 3 '5 '
OUT="$(run 2>/dev/null)"
ck "trailing-space max renders rp[3/5], not uncapped" '[ "$OUT" = "rp[3/5]" ]'

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
