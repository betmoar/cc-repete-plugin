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
# \r is stripped so a CRLF-edited state file still renders.
fmv() { # key
  awk -v k="$1" '
    /^---[[:space:]]*$/ { f++; next }
    f==1 && index($0, k":")==1 {
      sub("^" k ":[[:space:]]*", ""); gsub(/\r/, ""); print; exit
    }
    f>=2 { exit }
  ' "$LOOP"
}

active=$(fmv active)
[[ "$active" == "true" ]] || exit 0

iter=$(fmv iteration)
max=$(fmv max_iterations)
[[ "$iter" =~ ^[0-9]+$ ]] || iter=0

if [[ "$max" =~ ^[0-9]+$ ]] && [[ "$max" -gt 0 ]]; then
  printf 'rp[%s/%s]' "$iter" "$max"
else
  printf 'rp[%s]' "$iter"
fi
