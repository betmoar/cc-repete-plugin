#!/usr/bin/env bash
#
# repete Stop-hook loop engine.
#
# Three-way decision on every Stop attempt while a loop is active:
#   1. <repete-done>GOAL</repete-done>  matches mission_goal  -> tear down, exit clean
#   2. <repete-checkpoint>...</repete-checkpoint> present      -> yield to user for approval
#   3. otherwise                                                -> block + re-inject (autonomous)
#
# Plus two safety yields that also stop autonomous looping:
#   - max_iterations reached
#   - context_budget_lines exceeded  -> prompt user to /clear then /repete-continue
#
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
REPETE_DIR="$PROJECT_DIR/.repete"
STATE_FILE="$REPETE_DIR/loop.local.md"
TRANSITION_FILE="$REPETE_DIR/transition.md"

# No active loop -> never interfere with a normal stop.
[[ -f "$STATE_FILE" ]] || exit 0

# Hard requirement: jq. Without it we cannot read the transcript safely, so
# fail open (allow the stop) rather than trap the user in a loop we can't steer.
command -v jq >/dev/null 2>&1 || exit 0

HOOK_INPUT="$(cat)"

# ---- frontmatter helpers -------------------------------------------------
FM="$(awk 'BEGIN{f=0} /^---[[:space:]]*$/{f++; next} f==1{print} f>=2{exit}' "$STATE_FILE")"
fm() { printf '%s\n' "$FM" | grep "^$1:" | head -1 | sed "s/^$1:[[:space:]]*//" | sed 's/^"\(.*\)"$/\1/'; }

set_fm() { # key value  (atomic update of a key ONLY within the first frontmatter block)
  # awk -v makes the value literal, so '&', '|', '/' in a value are safe (C2),
  # and the f==1 guard means body lines matching "^key:" are never touched (C1).
  local key="$1" val="$2" tmp="$STATE_FILE.tmp.$$"
  awk -v k="$key" -v v="$val" '
    /^---[[:space:]]*$/ { f++; print; next }
    f==1 && index($0, k":")==1 { print k": " v; next }
    { print }
  ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

emit() { jq -n --arg m "$1" '{systemMessage:$m}'; }

ACTIVE="$(fm active)"
[[ "$ACTIVE" == "true" ]] || exit 0

# Already paused awaiting the user -> let the stop go through untouched.
case "$(fm status)" in
  paused-checkpoint|paused-context|paused-max|paused) exit 0 ;;
esac

# ---- session isolation ---------------------------------------------------
# Commands can rarely capture the session id at setup time, so the hook stamps it
# itself on first sight (M3). After that, a Stop from a different session is ignored.
STATE_SESSION="$(fm session_id)"
HOOK_SESSION="$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""')"
if [[ -z "$STATE_SESSION" && -n "$HOOK_SESSION" ]]; then
  set_fm session_id "\"$HOOK_SESSION\""
  STATE_SESSION="$HOOK_SESSION"
fi
[[ -n "$STATE_SESSION" && -n "$HOOK_SESSION" && "$STATE_SESSION" != "$HOOK_SESSION" ]] && exit 0

ITERATION="$(fm iteration)"; [[ "$ITERATION" =~ ^[0-9]+$ ]] || ITERATION=1
PHASE="$(fm phase)";         [[ "$PHASE" =~ ^[0-9]+$ ]]     || PHASE=1
MAX_ITER="$(fm max_iterations)";        [[ "$MAX_ITER" =~ ^[0-9]+$ ]]   || MAX_ITER=0
CTX_BUDGET="$(fm context_budget_lines)";[[ "$CTX_BUDGET" =~ ^[0-9]+$ ]] || CTX_BUDGET=0
MISSION_GOAL="$(fm mission_goal)"

# ---- last assistant message ----------------------------------------------
TRANSCRIPT="$(printf '%s' "$HOOK_INPUT" | jq -r '.transcript_path // ""')"
LAST_OUTPUT=""
if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
  LAST_OUTPUT="$(jq -rs '
      [ .[] | select(.message.role=="assistant") ] | last
      | (.message.content // [])
      | if type=="array" then (map(select(.type=="text").text) | join("\n")) else tostring end
    ' "$TRANSCRIPT" 2>/dev/null || echo "")"
fi

norm() { printf '%s' "$1" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'; }

# A checkpoint always wins over a done in the same message (I2): the human-gated
# path is the safe one, so an accidental co-occurrence never tears the loop down.
HAS_CHECKPOINT=0
printf '%s' "$LAST_OUTPUT" | perl -0777 -ne 'exit(/<repete-checkpoint>.*?<\/repete-checkpoint>/s ? 0 : 1)' && HAS_CHECKPOINT=1

# ---- (1) mission done? ----------------------------------------------------
if [[ $HAS_CHECKPOINT -eq 0 && -n "$MISSION_GOAL" && "$MISSION_GOAL" != "null" ]]; then
  DONE="$(printf '%s' "$LAST_OUTPUT" | perl -0777 -ne 'print "$1" if /<repete-done>(.*?)<\/repete-done>/s' 2>/dev/null)"
  if [[ -n "$DONE" && "$(norm "$DONE")" == "$(norm "$MISSION_GOAL")" ]]; then
    set_fm status done
    set_fm active false
    emit "✅ repete: mission goal met — loop complete after phase ${PHASE}. State left in .repete/ for review."
    exit 0
  fi
fi

# ---- (2) loop exit goal hit -> checkpoint for the user --------------------
if [[ $HAS_CHECKPOINT -eq 1 ]]; then
  PAYLOAD="$(printf '%s' "$LAST_OUTPUT" | perl -0777 -ne 'print "$1" if /<repete-checkpoint>(.*?)<\/repete-checkpoint>/s' 2>/dev/null)"
  printf '%s\n' "$PAYLOAD" > "$TRANSITION_FILE"
  set_fm status paused-checkpoint
  emit "⏸ repete checkpoint (phase ${PHASE}, iteration ${ITERATION}). Proposed next payload → .repete/transition.md. Review/edit it, then /repete-continue to launch the next loop, or /repete-cancel to stop."
  exit 0
fi

# ---- safety yield: max iterations ----------------------------------------
# iteration counts completed work turns: with max_iterations=3, turns 1,2,3 run,
# then this fires (3>=3) before a 4th. So N = N work cycles, as intended.
if [[ "$MAX_ITER" -gt 0 && "$ITERATION" -ge "$MAX_ITER" ]]; then
  set_fm status paused-max
  emit "🛑 repete: max_iterations (${MAX_ITER}) reached in phase ${PHASE}. Loop paused. /repete-continue to push the cap and resume, or /repete-cancel."
  exit 0
fi

# ---- safety yield: context budget (rot-as-checkpoint) --------------------
if [[ "$CTX_BUDGET" -gt 0 && -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
  LINES="$(wc -l < "$TRANSCRIPT" 2>/dev/null | tr -d ' ')"
  if [[ "${LINES:-0}" -gt "$CTX_BUDGET" ]]; then
    set_fm status paused-context
    emit "🧹 repete: context budget (${CTX_BUDGET} lines) exceeded. Run /clear, then /repete-continue to resume this loop with a fresh context rehydrated from .repete/."
    exit 0
  fi
fi

# ---- (3) autonomous continue: block + re-inject --------------------------
NEXT=$((ITERATION + 1))
set_fm iteration "$NEXT"

# Everything after the SECOND '---'. Print-before-increment so a '---' horizontal
# rule inside the body is preserved, not swallowed (I1).
PAYLOAD_BODY="$(awk 'p{print} /^---[[:space:]]*$/{c++; if(c==2)p=1}' "$STATE_FILE")"

RULES="$(cat <<EOF

--- repete standing rules (phase ${PHASE} · iteration ${NEXT}) ---
- Re-read .repete/MISSION.md, .repete/todo-next.md and the cards in .repete/lessons/ BEFORE acting. Work from files and git, not from memory in this conversation.
- The moment you notice work outside this loop's exit goal, append it to .repete/todo-next.md (one line: what + why + where). Do not chase it now.
- When you hit a mistake, dead-end, or a fix that did not work, write a lesson card to .repete/lessons/ in the format the template defines. Reflect briefly: what you tried, what happened, the rule for next time.
- When THIS loop's exit goal is satisfied (and only then): output a <repete-checkpoint>...</repete-checkpoint> block containing your proposed next-loop payload — seeded from .repete/todo-next.md and what you learned — then stop. The user approves it before the next loop starts.
- Only when the MISSION goal stated in .repete/MISSION.md is unequivocally and verifiably TRUE: output <repete-done> with that exact goal string </repete-done>. Never emit either sentinel just to escape the loop.
EOF
)"

REINJECT="$PAYLOAD_BODY$RULES"

jq -n --arg r "$REINJECT" --arg m "🔄 repete · phase ${PHASE} · iteration ${NEXT}" \
  '{decision:"block", reason:$r, systemMessage:$m}'
exit 0
