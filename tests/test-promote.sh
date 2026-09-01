#!/usr/bin/env bash
# tests/test-promote.sh — behavioral tests for hooks/promote.sh (issue #8).
# Run standalone: bash tests/test-promote.sh
# shellcheck disable=SC2016,SC2034  # ck() takes each assertion as a literal
# string and evals it, so single quotes are deliberate and $OUT/$RC/etc. are
# used there — mirrors tests/test-hooks.sh's convention.
#
# ASSERTION CONVENTION: mirrors tests/test-hooks.sh (issue #17) — prefer a
# direct exit-code/grep check over piping through jq where jq isn't needed;
# promote.sh's output is plain text/frontmatter, not JSON, so there's no
# jq -e pipefail trap here, but the same "assert on exit status, not on a
# truncated pipe" discipline applies.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P="$ROOT/hooks/promote.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ck(){ if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }

# Build a minimal loop.local.md with given phase/iteration/stale_count/status/
# active/session_id and a given body (default body includes a BODY-level
# "status:" line to exercise C1).
scaffold(){ # phase iteration stale_count status active session_id [body]
  local phase="$1" iter="$2" stale="$3" status="$4" active="$5" sess="$6"
  local body="${7:-BODY line one
status: fake-body-line
BODY line two with a literal \\ backslash}"
  rm -rf "$TMP/.repete"; mkdir -p "$TMP/.repete"
  {
    printf -- '---\nactive: %s\nphase: %s\niteration: %s\nstale_count: %s\nstatus: %s\nsession_id: %s\n---\n' \
      "$active" "$phase" "$iter" "$stale" "$status" "$sess"
    printf '%s\n' "$body"
  } > "$TMP/.repete/loop.local.md"
}

fmval(){ # key file
  awk -v k="$1" 'BEGIN{f=0} /^---[[:space:]]*$/{f++; next} f==1 && index($0,k":")==1{sub("^"k":[[:space:]]*",""); print; exit} f>=2{exit}' "$2" | tr -d '\r'
}

echo "== All 6 keys written from a scaffolded state file =="
scaffold 2 5 2 paused-checkpoint true '"S1"'
OUT="$(bash "$P" "$TMP/.repete/loop.local.md")"; RC=$?
ck "exit 0"                'test "$RC" -eq 0'
ck "phase incremented 2->3" '[ "$(fmval phase "$TMP/.repete/loop.local.md")" = "3" ]'
ck "iteration -> 1"         '[ "$(fmval iteration "$TMP/.repete/loop.local.md")" = "1" ]'
ck "stale_count -> 0"       '[ "$(fmval stale_count "$TMP/.repete/loop.local.md")" = "0" ]'
ck "status -> running"      '[ "$(fmval status "$TMP/.repete/loop.local.md")" = "running" ]'
ck "active -> true"         '[ "$(fmval active "$TMP/.repete/loop.local.md")" = "true" ]'
ck 'session_id -> ""'       '[ "$(fmval session_id "$TMP/.repete/loop.local.md")" = "\"\"" ]'
ck "stdout names phase transition" 'printf "%s" "$OUT" | grep -q "phase 2 -> 3"'

echo "== Body preserved byte-for-byte across the frontmatter write =="
scaffold 1 1 0 running false '""'
BEFORE_BODY="$(awk 'f{print} /^---[[:space:]]*$/{c++; if(c==2)f=1}' "$TMP/.repete/loop.local.md")"
bash "$P" "$TMP/.repete/loop.local.md" >/dev/null
AFTER_BODY="$(awk 'f{print} /^---[[:space:]]*$/{c++; if(c==2)f=1}' "$TMP/.repete/loop.local.md")"
ck "body identical before/after" '[ "$BEFORE_BODY" = "$AFTER_BODY" ]'

echo "== A state file MISSING a key still gets it (C3 append) =="
rm -rf "$TMP/.repete"; mkdir -p "$TMP/.repete"
printf -- '---\nactive: true\nphase: 4\n---\nBODY only\n' > "$TMP/.repete/loop.local.md"
bash "$P" "$TMP/.repete/loop.local.md" >/dev/null; RC=$?
ck "exit 0 on missing keys"     'test "$RC" -eq 0'
ck "phase incremented 4->5"     '[ "$(fmval phase "$TMP/.repete/loop.local.md")" = "5" ]'
ck "iteration appended -> 1"    '[ "$(fmval iteration "$TMP/.repete/loop.local.md")" = "1" ]'
ck "stale_count appended -> 0"  '[ "$(fmval stale_count "$TMP/.repete/loop.local.md")" = "0" ]'
ck "status appended -> running" '[ "$(fmval status "$TMP/.repete/loop.local.md")" = "running" ]'
ck 'session_id appended -> ""'  '[ "$(fmval session_id "$TMP/.repete/loop.local.md")" = "\"\"" ]'
ck "body still intact"          'grep -q "^BODY only$" "$TMP/.repete/loop.local.md"'

echo "== A fenceless state file gets the key + repaired fence (#11) =="
rm -rf "$TMP/.repete"; mkdir -p "$TMP/.repete"
printf -- '---\nactive: true\nphase: 1\nNo closing fence, body glued on\n' > "$TMP/.repete/loop.local.md"
bash "$P" "$TMP/.repete/loop.local.md" >/dev/null; RC=$?
ck "exit 0 on fenceless file"        'test "$RC" -eq 0'
ck "fence repaired (closing --- present)" 'grep -qE "^---[[:space:]]*$" "$TMP/.repete/loop.local.md"'
ck "all 6 keys land somewhere in file" \
  '[ "$(grep -cE "^(phase|iteration|stale_count|status|active|session_id):" "$TMP/.repete/loop.local.md")" -ge 6 ]'
ck "byte-intact body line survives" 'grep -q "No closing fence, body glued on" "$TMP/.repete/loop.local.md"'

echo "== A BODY line matching ^status: is NOT rewritten (C1) =="
scaffold 1 1 0 paused-checkpoint true '""' 'status: this-is-body-prose-not-frontmatter
another body line'
bash "$P" "$TMP/.repete/loop.local.md" >/dev/null
ck "body 'status:' line untouched" 'grep -q "^status: this-is-body-prose-not-frontmatter$" "$TMP/.repete/loop.local.md"'
ck "frontmatter status IS running"  '[ "$(fmval status "$TMP/.repete/loop.local.md")" = "running" ]'
# Exactly one line in the FULL file should read "status: running" (frontmatter);
# the body's "status: this-is-body-prose..." must not have been touched/duplicated.
ck "exactly one frontmatter status:running line" \
  '[ "$(grep -cxE "status: running" "$TMP/.repete/loop.local.md")" -eq 1 ]'

echo "== A value with a literal backslash round-trips (C2/#10) =="
scaffold 1 1 0 paused-checkpoint true '""' 'a line with a literal \ backslash in the body'
bash "$P" "$TMP/.repete/loop.local.md" >/dev/null
ck "literal backslash body line intact" 'grep -qF "a line with a literal \ backslash in the body" "$TMP/.repete/loop.local.md"'
# The written keys themselves are plain literals (true/running/0/1/""), so the
# C2 guarantee under test here is that awk -v was NOT used anywhere in the
# rewrite path (a body backslash would otherwise get eaten by -v's escape
# processing) — verified by the unmodified body line above.

echo "== Unwritable file -> non-zero exit + message =="
scaffold 1 1 0 paused-checkpoint true '""'
chmod 444 "$TMP/.repete/loop.local.md"
ERR="$(bash "$P" "$TMP/.repete/loop.local.md" 2>&1 1>/dev/null)"; RC=$?
chmod 644 "$TMP/.repete/loop.local.md"
ck "non-zero exit on unwritable file" 'test "$RC" -ne 0'
ck "stderr names the failure"         'printf "%s" "$ERR" | grep -qi "not writable"'

echo "== Missing state file -> non-zero exit + message =="
ERR="$(bash "$P" "$TMP/.repete/does-not-exist.md" 2>&1 1>/dev/null)"; RC=$?
ck "non-zero exit on missing file" 'test "$RC" -ne 0'
ck "stderr names the missing file" 'printf "%s" "$ERR" | grep -qi "not found"'

echo "== Malformed phase value -> non-zero exit + message =="
scaffold notanumber 1 0 paused-checkpoint true '""'
ERR="$(bash "$P" "$TMP/.repete/loop.local.md" 2>&1 1>/dev/null)"; RC=$?
ck "non-zero exit on malformed phase" 'test "$RC" -ne 0'
ck "stderr names the phase problem"   'printf "%s" "$ERR" | grep -qi "phase"'
ck "file left unmodified on malformed phase" 'grep -qE "^phase: notanumber" "$TMP/.repete/loop.local.md"'

echo "== No argument -> non-zero exit + message =="
ERR="$(bash "$P" 2>&1 1>/dev/null)"; RC=$?
ck "non-zero exit on no argument" 'test "$RC" -ne 0'
ck "stderr names usage"           'printf "%s" "$ERR" | grep -qi "usage"'

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
