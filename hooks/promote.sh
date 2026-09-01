#!/usr/bin/env bash
#
# promote.sh — atomic checkpoint-promotion for /repete-continue's
# paused-checkpoint branch (issue #8).
#
# FAILURE DIRECTION — the opposite of hooks/stop-hook.sh, deliberately:
# the Stop hook may ONLY fail open (never trap a Stop the loop can't steer).
# promote.sh is NOT a Stop-hook path: it runs once, human-gated, invoked
# directly from /repete-continue after the user has already reviewed and
# approved the next payload. A silent partial write here — one of the six
# frontmatter keys missing because awk choked on a weird value, or the file
# was read-only — IS the exact defect issue #8 exists to fix (an agent
# hand-editing frontmatter and missing a key, silently killing or
# miscounting the resumed loop). So promote.sh fails LOUD: any failure to
# read the current state, parse `phase`, or persist all six keys is a
# non-zero exit with a message naming exactly what could not be written.
# Do NOT "harmonize" this into fail-open to match the hook — the two run in
# opposite contexts (unattended loop vs. one human-gated command) and need
# opposite failure directions.
#
# Writes exactly six frontmatter keys, atomically, in one awk pass, within
# the FIRST frontmatter block only:
#   phase        -> current value + 1
#   iteration    -> 1
#   stale_count  -> 0
#   status       -> running
#   active       -> true
#   session_id   -> "" (quoted empty string, matching the schema's convention)
#
# It does NOT touch the body: the payload-promotion (replacing the body with
# the approved checkpoint payload) stays a Write/Edit the calling command
# performs directly — body content is arbitrary multi-line user-reviewed
# text, not a fixed key/value pair, and routing it through this script's
# argv/ENVIRON would just re-invent Edit with worse ergonomics for zero
# atomicity gain (the frontmatter write below is already atomic on its own).
#
# Usage: promote.sh <path-to-loop.local.md>
#
# Mirrors set_fm()'s three documented guarantees from hooks/stop-hook.sh,
# generalized to six keys in one pass instead of one:
#   C1: only the FIRST frontmatter block is touched; a BODY line matching
#       "^key:" is never rewritten.
#   C2: values travel via ENVIRON, not awk -v (issue #10 — -v runs the value
#       through awk's escape processing and eats a literal backslash).
#   C3: a missing key is APPENDED before the closing '---', never dropped.
#   #11: a frontmatter opened and never closed gets every missing key
#       appended at EOF, with the closing '---' written after them.
set -uo pipefail

STATE_FILE="${1:-}"

if [[ -z "$STATE_FILE" ]]; then
  echo "promote.sh: FAIL — no state file path given (usage: promote.sh <path-to-loop.local.md>)" >&2
  exit 1
fi

if [[ ! -f "$STATE_FILE" ]]; then
  echo "promote.sh: FAIL — state file not found: $STATE_FILE" >&2
  exit 1
fi

# ---- read current phase (scoped to the FIRST frontmatter block, mirrors fm()/C1) ----
CUR_PHASE_RAW="$(awk '
  BEGIN{f=0}
  /^---[[:space:]]*$/{f++; next}
  f==1 && index($0,"phase:")==1 { sub(/^phase:[[:space:]]*/,""); print; exit }
  f>=2{exit}
' "$STATE_FILE" | tr -d '\r' | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/')"

if [[ ! "$CUR_PHASE_RAW" =~ ^[0-9]{1,18}$ ]]; then
  echo "promote.sh: FAIL — 'phase' in $STATE_FILE is missing or not a valid integer (got: '${CUR_PHASE_RAW}')" >&2
  exit 1
fi

# Decimal-normalize (mirrors num10 in stop-hook.sh): a leading zero like "08"
# would be read as octal by bash arithmetic otherwise.
CUR_PHASE=$((10#$CUR_PHASE_RAW))
NEW_PHASE=$((CUR_PHASE + 1))

if [[ ! -w "$STATE_FILE" ]]; then
  echo "promote.sh: FAIL — $STATE_FILE is not writable (read-only file or directory?)" >&2
  exit 1
fi

TMP="$STATE_FILE.tmp.$$"

RP_PHASE="$NEW_PHASE" \
RP_ITERATION="1" \
RP_STALE_COUNT="0" \
RP_STATUS="running" \
RP_ACTIVE="true" \
RP_SESSION_ID='""' \
awk '
  BEGIN {
    keys[1]="phase";       vals["phase"]       = ENVIRON["RP_PHASE"]
    keys[2]="iteration";   vals["iteration"]   = ENVIRON["RP_ITERATION"]
    keys[3]="stale_count"; vals["stale_count"] = ENVIRON["RP_STALE_COUNT"]
    keys[4]="status";      vals["status"]      = ENVIRON["RP_STATUS"]
    keys[5]="active";      vals["active"]      = ENVIRON["RP_ACTIVE"]
    keys[6]="session_id";  vals["session_id"]  = ENVIRON["RP_SESSION_ID"]
    nkeys = 6
    f = 0
  }
  /^---[[:space:]]*$/ {
    f++
    if (f==2) {
      # Closing fence of the first block: append any key not yet written (C3).
      for (i=1; i<=nkeys; i++) {
        k = keys[i]
        if (!written[k]) { print k": " vals[k]; written[k]=1 }
      }
    }
    print
    next
  }
  f==1 {
    matched = 0
    for (i=1; i<=nkeys; i++) {
      k = keys[i]
      if (!written[k] && index($0, k":")==1) {
        print k": " vals[k]
        written[k] = 1
        matched = 1
        break
      }
    }
    if (!matched) print
    next
  }
  { print }
  END {
    # Fenceless file (#11): frontmatter opened, never closed. Append every
    # missing key and the repaired closing fence at EOF — the only possible
    # landing spot, same reasoning as set_fm(): with no closing fence, f==1
    # covers the whole remainder and nothing distinguishes a trailing key
    # from body prose.
    if (f==1) {
      any_missing = 0
      for (i=1; i<=nkeys; i++) if (!written[keys[i]]) any_missing = 1
      if (any_missing) {
        for (i=1; i<=nkeys; i++) {
          k = keys[i]
          if (!written[k]) { print k": " vals[k]; written[k]=1 }
        }
        print "---"
      }
    }
  }
' "$STATE_FILE" > "$TMP"
AWK_STATUS=$?

if [[ $AWK_STATUS -ne 0 ]]; then
  rm -f "$TMP" 2>/dev/null
  echo "promote.sh: FAIL — awk failed while rewriting $STATE_FILE (exit $AWK_STATUS); no changes written" >&2
  exit 1
fi

if ! mv "$TMP" "$STATE_FILE" 2>/dev/null; then
  rm -f "$TMP" 2>/dev/null
  echo "promote.sh: FAIL — could not replace $STATE_FILE (mv failed; disk full or permissions?)" >&2
  exit 1
fi

echo "promote.sh: OK — phase ${CUR_PHASE} -> ${NEW_PHASE}, iteration -> 1, stale_count -> 0, status -> running, active -> true, session_id -> \"\""
exit 0
