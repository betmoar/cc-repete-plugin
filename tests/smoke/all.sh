#!/usr/bin/env bash
# Run every smoke suite; non-zero exit if any assertion failed.
set -uo pipefail
here="$(dirname "${BASH_SOURCE[0]}")"
rc=0
for s in control-flow edge-cases layers; do
  f="$here/$s.sh"
  [[ -f "$f" ]] || { echo "(skip: $s.sh not present yet)"; continue; }
  echo "######## $s ########"
  bash "$f" || rc=1
done
exit "$rc"
