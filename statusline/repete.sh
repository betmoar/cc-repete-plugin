#!/usr/bin/env bash
# repete statusline segment — renders the active loop's progress as rp[iter/max]
# (or rp[iter] when uncapped). Prints nothing (exit 0) when no loop is active.
#
# State lives at <project>/.repete/loop.local.md, written by the Stop hook
# (hooks/stop-hook.sh resolves the project as CLAUDE_PROJECT_DIR:-$PWD). The
# statusline stdin carries that same project path, so we read it from the
# session JSON (.workspace.project_dir // .cwd) to match the hook's view, with
# env/PWD fallbacks for when jq is absent or the field is missing.
set -uo pipefail

# Drain stdin only when it's a pipe; a TTY stdin (segment run manually, or a host
# that forgets to close it) would block `cat` forever. Either way we fall back to
# env/PWD below, so a terminal just means "no JSON".
IN=""
[[ -t 0 ]] || IN="$(cat)"

PROJ=""
if command -v jq >/dev/null 2>&1; then
  PROJ="$(printf '%s' "$IN" | jq -r '.workspace.project_dir // .cwd // empty' 2>/dev/null)"
fi
[[ -n "$PROJ" ]] || PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"

LOOP="$PROJ/.repete/loop.local.md"
[[ -f "$LOOP" ]] || exit 0

# Read a key from the FIRST frontmatter block only, exactly like the hook's
# fm() — a whole-file scan also matched body prose that happens to start with
# "active:"/"iteration:", capturing multi-line garbage and blanking the segment.
# \r is stripped so a CRLF-edited state file still renders; a leading UTF-8 BOM
# is stripped too (same Windows-artifact family, audit F7); surrounding double
# quotes are stripped for PARITY with the hook's fm() — a template-style quoted
# `active: "true"` must render, not blank the segment (audit F9).
fmv() { # key
  # BOM stripped with perl (BSD awk cannot match the hex bytes, audit F7).
  # Failure direction: NO perl -> read raw via cat (pre-F7 behavior: a BOM'd
  # file renders nothing, same as before the fix) — never an empty read that
  # blanks every segment (toolkit review critical).
  local reader
  if command -v perl >/dev/null 2>&1; then
    reader="perl -pe 's/^\xEF\xBB\xBF// if \$. == 1'"
  else
    reader="cat"
  fi
  # shellcheck disable=SC2086  # $reader is a fixed two-word command chosen above
  eval "$reader \"\$LOOP\"" 2>/dev/null \
  | awk -v k="$1" '
    /^---[[:space:]]*$/ { f++; next }
    f==1 && index($0, k":")==1 {
      sub("^" k ":[[:space:]]*", ""); gsub(/\r/, "")
      sub(/^"/, ""); sub(/"$/, "")
      print; exit
    }
    f>=2 { exit }
  '
}
# Decimal-normalize: leading-zero values are DECIMAL ("09" = 9), not octal —
# bash [[ -gt ]] throws "value too great for base" on 08/09 and errors the cap
# test to false, rendering a capped loop as uncapped (audit F1). Overflow guard:
# >18 digits wraps negative in $((10#..)) and disables the cap silently — such
# values default to 0 (uncapped, same as malformed), never a wrapped negative.
num10() { local v="$1"; [[ "$v" =~ ^[0-9]{1,18}$ ]] || v=0; printf '%d' "$((10#$v))"; }

active=$(fmv active)
[[ "$active" == "true" ]] || exit 0

iter=$(num10 "$(fmv iteration)")
max=$(num10 "$(fmv max_iterations)")
status=$(fmv status)

# Status differentiation (audit F14): a paused/stale loop must not render
# identically to a healthy running one — the user glancing at the bar needs to
# see the loop is waiting on THEM. Transient 'summarizing' and 'running' render
# plain; every paused-* state gets a ·wait marker with a short tag.
seg="rp[${iter}"
[[ "$max" -gt 0 ]] && seg+="/${max}"
seg+="]"
case "$status" in
  paused-checkpoint) seg+=" ·ck" ;;
  paused-context)    seg+=" ·ctx" ;;
  paused-max)        seg+=" ·max" ;;
  paused-stale)      seg+=" ·stale" ;;
  *) ;;
esac
printf '%s' "$seg"
