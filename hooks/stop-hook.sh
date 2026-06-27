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
#   - context_budget_lines exceeded  -> two-step yield: first re-inject one turn
#     to write a .repete/handoff.md snapshot (transient 'summarizing' status),
#     then prompt the user to /clear and /repete-continue. While 'summarizing',
#     that budget two-step owns the Stop: sentinels and the iteration cap are
#     suppressed so nothing diverts the loop out of the /clear flow.
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

# ---- lesson catalog helpers ----------------------------------------------
# Read one frontmatter value from a lesson card. The card template carries a
# leading <!-- ... --> comment BEFORE its '---' block, so key off the first
# '---'-delimited block (f==1), exactly as the state-file reader does.
card_field() { # file key
  # Strip the "key: " prefix, then any trailing " # comment" (the shipped
  # lesson-card template carries inline comments on its frontmatter lines —
  # e.g. `severity: high   # how badly it bit`), then trim surrounding space.
  # Without the comment-strip a filled card's severity becomes "high  # …",
  # which fails the case match in build_catalog and silently drops the card.
  awk -v k="$2" '
    BEGIN{f=0}
    /^---[[:space:]]*$/{f++; next}
    f==1 && index($0, k":")==1 {
      sub("^"k":[[:space:]]*","")
      sub(/[[:space:]]+#.*$/,"")
      gsub(/^[[:space:]]+|[[:space:]]+$/,"")
      print; exit
    }
    f>=2{exit}
  ' "$1"
}

# Build a metadata-only catalog: one line per valid card, ranked severity
# (high>medium>low) then hits (desc), capped, with an overflow note. Robust:
# any card missing slug or a recognized severity is skipped silently, never
# crashing the builder or emitting a garbled line (spec §5 parser robustness).
build_catalog() { # cap
  local cap="$1" dir="$REPETE_DIR/lessons"
  [[ -d "$dir" ]] || return 0
  local f slug sev hits tags rank rows="" total=0
  for f in "$dir"/*.md; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == "_TEMPLATE.md" ]] && continue
    slug="$(card_field "$f" slug)"
    sev="$(card_field "$f" severity)"
    [[ -n "$slug" && -n "$sev" ]] || continue
    case "$sev" in
      high) rank=0 ;; medium) rank=1 ;; low) rank=2 ;;
      *) continue ;;
    esac
    hits="$(card_field "$f" hits)"; [[ "$hits" =~ ^[0-9]+$ ]] || hits=1
    hits=$((10#$hits))   # force base-10: a leading-zero hits (08/09) is decimal, not octal
    tags="$(card_field "$f" tags | tr -d '[] ')"
    rows+="$(printf '%d\t%09d\t%s\t%s\t%s\t%s' "$rank" "$((999999999 - hits))" "$slug" "$tags" "$sev" "$hits")"$'\n'
    total=$((total + 1))
  done
  [[ "$total" -gt 0 ]] || return 0
  local shown="$total"
  [[ "$cap" -gt 0 ]] && shown="$cap"
  printf 'Known lessons (consult before acting; Read only the relevant ones):\n'
  printf '%s' "$rows" | sort -t$'\t' -k1,1n -k2,2n | head -n "$shown" \
    | awk -F'\t' '{printf "  %-22s [%s] %-6s hits:%s\n", $3, $4, $5, $6}'
  if [[ "$cap" -gt 0 && "$total" -gt "$cap" ]]; then
    printf '  … +%d more — grep .repete/lessons/\n' "$((total - cap))"
  fi
}

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

STATUS="$(fm status)"
ITERATION="$(fm iteration)"; [[ "$ITERATION" =~ ^[0-9]+$ ]] || ITERATION=1
PHASE="$(fm phase)";         [[ "$PHASE" =~ ^[0-9]+$ ]]     || PHASE=1
MAX_ITER="$(fm max_iterations)";        [[ "$MAX_ITER" =~ ^[0-9]+$ ]]   || MAX_ITER=0
CTX_BUDGET="$(fm context_budget_lines)";[[ "$CTX_BUDGET" =~ ^[0-9]+$ ]] || CTX_BUDGET=0
MISSION_GOAL="$(fm mission_goal)"
LESSONS_ENABLED="$(fm lessons_enabled)";     [[ "$LESSONS_ENABLED" == "true" ]]   || LESSONS_ENABLED=false
TODO_NEXT_ENABLED="$(fm todo_next_enabled)"; [[ "$TODO_NEXT_ENABLED" == "true" ]] || TODO_NEXT_ENABLED=false
AUTONOMOUS="$(fm autonomous)";               [[ "$AUTONOMOUS" == "true" ]]        || AUTONOMOUS=false

# ---- autonomous safety backstop ------------------------------------------
# Autonomous loops force HAS_CHECKPOINT=0 (below), so the per-loop checkpoint
# can't pause them — only <repete-done>, max_iterations, and the context budget
# can. If BOTH numeric budgets are disabled (0), a buggy/unreachable mission
# goal would block Stop forever with no out-of-band escape. Refuse that trap:
# stamp a conservative iteration cap into state (visible to statusline and
# /repete-status), and tell the user once. They can raise or clear it.
AUTO_CAP_DEFAULT=25
AUTO_CAP_APPLIED=0
if [[ "$AUTONOMOUS" == "true" && "$MAX_ITER" -eq 0 && "$CTX_BUDGET" -eq 0 ]]; then
  MAX_ITER="$AUTO_CAP_DEFAULT"
  set_fm max_iterations "$MAX_ITER"
  AUTO_CAP_APPLIED=1
fi

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

# Autonomous loops never yield at a sub-goal: treat any checkpoint sentinel as
# absent so the done-check and re-inject below run normally. Only <repete-done>
# and the iteration cap stop an autonomous loop.
[[ "$AUTONOMOUS" == "true" ]] && HAS_CHECKPOINT=0

# While 'summarizing' (the pass-1 handoff turn), the agent was told NOT to emit
# any sentinel; if it does so by accident, the pass-2 budget yield below must
# still win — otherwise a stray <repete-checkpoint>/<repete-done> would divert
# the loop out of the /clear flow. Suppress sentinel handling in this state.
if [[ "$STATUS" != "summarizing" ]]; then

# ---- (1) mission done? ----------------------------------------------------
if [[ $HAS_CHECKPOINT -eq 0 && -n "$MISSION_GOAL" && "$MISSION_GOAL" != "null" ]]; then
  DONE="$(printf '%s' "$LAST_OUTPUT" | perl -0777 -ne 'print "$1" if /<repete-done>(.*?)<\/repete-done>/s' 2>/dev/null)"
  if [[ -n "$DONE" && "$(norm "$DONE")" == "$(norm "$MISSION_GOAL")" ]]; then
    set_fm status "done"
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

fi  # end: sentinel handling suppressed while 'summarizing'

# ---- safety yield: max iterations ----------------------------------------
# iteration counts completed work turns: with max_iterations=3, turns 1,2,3 run,
# then this fires (3>=3) before a 4th. So N = N work cycles, as intended.
# Skip while 'summarizing': pass-1 already truncated handoff.md and is awaiting
# the snapshot turn, so letting the cap preempt here would yield paused-max with
# an empty handoff and lose the in-flight delta. The budget two-step below owns
# this Stop; the cap re-applies normally once the loop returns to 'running'.
if [[ "$STATUS" != "summarizing" && "$MAX_ITER" -gt 0 && "$ITERATION" -ge "$MAX_ITER" ]]; then
  set_fm status paused-max
  emit "🛑 repete: max_iterations (${MAX_ITER}) reached in phase ${PHASE}. Loop paused. /repete-continue to push the cap and resume, or /repete-cancel."
  exit 0
fi

# ---- safety yield: context budget (rot-as-checkpoint) --------------------
# Two steps so the restart can be lossless: the conversation /clear discards any
# in-flight state not yet on disk, so before yielding we spend ONE re-inject
# turn having the agent snapshot that delta to .repete/handoff.md. The restart
# is lossless only if that snapshot is actually written — pass 2 verifies it and
# warns if it's missing/empty, in which case rehydrate falls back to durable
# on-disk state (committed work, git, loop body).
#   pass 1 (any non-'summarizing' status) -> mark 'summarizing', block + ask for handoff
#   pass 2 (status 'summarizing')         -> verify handoff, yield for /clear
if [[ "$CTX_BUDGET" -gt 0 && -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
  LINES="$(wc -l < "$TRANSCRIPT" 2>/dev/null | tr -d ' ')"
  if [[ "${LINES:-0}" -gt "$CTX_BUDGET" ]]; then
    if [[ "$STATUS" == "summarizing" ]]; then
      set_fm status paused-context
      # Treat a handoff as "saved" only if the agent actually FILLED it. A bare
      # -s/non-whitespace test would pass a copied-but-unfilled template, since
      # the template's HTML comment, "## headings" and "<placeholder>" lines are
      # all non-whitespace — a false "saved" that leads the user to /clear and
      # lose the delta. So strip the structural scaffolding (mirrors the
      # constitution "effectively-empty -> skip" test below) and require real
      # content to remain: drop <!-- --> comments, markdown headings, lines that
      # are only an <angle-bracket placeholder>, and blank lines.
      HANDOFF_REAL=""
      if [[ -f "$REPETE_DIR/handoff.md" ]]; then
        # Decide "filled" by stripping ONLY the template's own scaffolding, then
        # checking whether anything remains. We strip the literal section
        # headings the template ships (not any '#'-leading line — so real content
        # like "#123 revert" or "# TODO finish parser" still counts), whole-line
        # <angle-bracket placeholders>, HTML comments, and blanks. Keeping the
        # heading list in sync with templates/handoff.md is the small coupling
        # cost of not misclassifying user content as scaffolding.
        HANDOFF_REAL="$(perl -0777 -pe 's/<!--.*?-->//gs' "$REPETE_DIR/handoff.md" 2>/dev/null \
          | grep -vxE '[[:space:]]*##[[:space:]]+(Done this stretch|In flight|Next concrete step|Open questions & risks)[[:space:]]*' \
          | grep -vE '^[[:space:]]*<[^>]*>[[:space:]]*$' \
          | grep -vE '^[[:space:]]*$' || true)"
      fi
      if [[ -n "$HANDOFF_REAL" ]]; then
        emit "🧹 repete: context budget (${CTX_BUDGET} lines) exceeded; handoff snapshot saved to .repete/handoff.md. Run /clear, then /repete-continue to resume this loop with a fresh context rehydrated from .repete/."
      else
        emit "⚠️ repete: context budget (${CTX_BUDGET} lines) exceeded but .repete/handoff.md is missing, empty, or still the unfilled template — the in-flight delta was NOT captured. You can still /clear then /repete-continue (rehydrate falls back to committed state, git, and the loop body), but expect to re-derive whatever was only in the cleared conversation."
      fi
      exit 0
    fi
    # pass 1: do NOT bump iteration (the snapshot turn is free) and re-inject a
    # minimal, focused brief — not the full payload/catalog/protocol.
    # Truncate any stale handoff first, so pass-2's filled-content test proves
    # THIS cycle's agent actually wrote one, not that an old snapshot lingers.
    : > "$REPETE_DIR/handoff.md"
    set_fm status summarizing
    HANDOFF_REINJECT='--- repete context checkpoint: write a handoff snapshot, then STOP ---
The context budget is reached and this conversation is about to be /clear-ed. Capture the in-flight state that is NOT yet on disk so the next session resumes losslessly.

Write .repete/handoff.md (overwrite it) with these sections, tight — under ~30 lines total:
- Done this stretch: what you just finished, with file paths / commit refs.
- In flight: what is half-done right now and exactly where you left off.
- Next concrete step: the single next action to take after the reload.
- Open questions & risks: anything unresolved the next session must know.

Write durable facts to their normal homes too if not already there (loop body, .repete/todo-next.md, a lesson card, a commit). Then STOP. Do NOT continue the loop work, and do NOT emit <repete-checkpoint> or <repete-done>.'
    jq -n --arg r "$HANDOFF_REINJECT" --arg m "🧹 repete · context budget reached — saving handoff snapshot before /clear" \
      '{decision:"block", reason:$r, systemMessage:$m}'
    exit 0
  fi
fi

# Recover from a stranded 'summarizing': every budget yield above exits, so
# reaching here means we are NOT over budget (raised cap, shrunk transcript, or
# budget disabled). Clear the transient status so we don't take the pass-2
# paused-context path on a future trip without first writing a fresh handoff.
if [[ "$STATUS" == "summarizing" ]]; then
  set_fm status running
  STATUS=running
  # The max-iterations yield above was skipped because status was 'summarizing'.
  # Now that we've returned to 'running', re-apply it here so a cap reached
  # during the handoff is still enforced on THIS Stop — otherwise the loop would
  # run one cycle past the configured cap before the next Stop catches it.
  if [[ "$MAX_ITER" -gt 0 && "$ITERATION" -ge "$MAX_ITER" ]]; then
    set_fm status paused-max
    emit "🛑 repete: max_iterations (${MAX_ITER}) reached in phase ${PHASE}. Loop paused. /repete-continue to push the cap and resume, or /repete-cancel."
    exit 0
  fi
fi

# ---- (3) autonomous continue: block + re-inject --------------------------
NEXT=$((ITERATION + 1))
set_fm iteration "$NEXT"

# Everything after the SECOND '---'. Print-before-increment so a '---' horizontal
# rule inside the body is preserved, not swallowed (I1).
PAYLOAD_BODY="$(awk 'p{print} /^---[[:space:]]*$/{c++; if(c==2)p=1}' "$STATE_FILE")"

# --- lessons catalog (metadata only; bodies are agent-retrieved on demand) -
CATALOG=""
if [[ "$LESSONS_ENABLED" == "true" ]]; then
  CATALOG_CAP="$(fm lesson_catalog_cap)"; [[ "$CATALOG_CAP" =~ ^[0-9]+$ ]] || CATALOG_CAP=8
  CATALOG="$(build_catalog "$CATALOG_CAP")"
fi

# --- user constitution (frozen, user-authored) ----------------------------
# Inject verbatim ONLY if it has real content. An unfilled starter is all HTML
# comments + blanks; injecting that every iteration is pure bloat, so treat
# "comments-and-whitespace only" as empty and skip (extends spec §7 "empty ->
# skip" to "effectively-empty -> skip").
CONSTITUTION=""
CONST_FILE="$REPETE_DIR/constitution.md"
if [[ -f "$CONST_FILE" ]]; then
  CONST_RAW="$(cat "$CONST_FILE" 2>/dev/null)"
  # Strip <!-- ... --> comment blocks (keep everything else). The stripped text is
  # what gets injected — comment noise must not ride every re-inject (spec §7
  # "stay short"). This is stricter-but-aligned with the spec's "verbatim": we
  # inject the user's real rules, minus HTML comments.
  CONST_NOCOMMENT="$(printf '%s' "$CONST_RAW" | perl -0777 -pe 's/<!--.*?-->//gs')"
  # Emptiness test: also drop blank lines; if nothing real remains, skip entirely
  # (an unfilled all-comments starter -> empty -> not injected).
  CONST_REAL="$(printf '%s' "$CONST_NOCOMMENT" | grep -v '^[[:space:]]*$' || true)"
  if [[ -n "$CONST_REAL" ]]; then
    # Trim leading + trailing blank lines (a stripped comment block leaves gaps),
    # but keep blank lines BETWEEN rules. Portable: no tac/tail -r (macOS lacks tac).
    # awk #1 drops leading blanks; awk #2 buffers and prints up to the last non-blank.
    CONSTITUTION="$(printf '%s' "$CONST_NOCOMMENT" \
      | awk 'NF{p=1} p' \
      | awk '{a[NR]=$0} END{last=NR; while(last>0 && a[last]~/^[[:space:]]*$/)last--; for(i=1;i<=last;i++)print a[i]}')"
  fi
fi

# --- engine protocol (frozen, hook-versioned) -----------------------------
# Read the shipped protocol template; fall back to an inline core if it is
# unreadable (missing/botched install). Fail-functional: the loop must never
# lose its two sentinels, matching the fail-open-on-missing-jq philosophy.
# shellcheck disable=SC2016  # ${PHASE}/${NEXT} are literal placeholder tokens,
# substituted below — they must NOT expand here (single quotes are deliberate).
PROTO_FALLBACK='
--- repete standing rules (phase ${PHASE} · iteration ${NEXT}) ---
- Work from files and git, not from memory in this conversation.
- Only when the MISSION goal in .repete/MISSION.md is verifiably TRUE: output <repete-done> with that exact goal string </repete-done>. Never emit it just to escape the loop.'
# Only attempt the read when CLAUDE_PLUGIN_ROOT is set; otherwise the
# expansion falls to a filesystem-root "/templates/protocol.md" that could
# read an unrelated file and silently mask the fallback.
PROTO=""
[[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]] && PROTO="$(cat "${CLAUDE_PLUGIN_ROOT}/templates/protocol.md" 2>/dev/null)"
[[ -n "$PROTO" ]] || PROTO="$PROTO_FALLBACK"
# shellcheck disable=SC2016  # single quotes make the search PATTERN the literal
# token '${PHASE}'/'${NEXT}'; this is the substitution, expanding it would break it.
PROTO="${PROTO//'${PHASE}'/$PHASE}"
# shellcheck disable=SC2016  # literal-token search pattern, see above.
PROTO="${PROTO//'${NEXT}'/$NEXT}"

# --- composed standing rules (gated by frontmatter flags) -----------------
# The frozen protocol carries only re-read / constitution / done-sentinel. The
# checkpoint sentinel and the lessons/todo journaling rules are OPT-IN: append
# them only when their flag is on, so a default loop stays quiet.
RULES_EXTRA=""
if [[ "$AUTONOMOUS" != "true" ]]; then
  RULES_EXTRA+=$'\n- When THIS loop'"'"'s exit goal is satisfied (and only then): output a <repete-checkpoint>...</repete-checkpoint> block with your proposed next-loop payload, then stop. The user approves it before the next loop starts. Never emit it just to escape the loop.'
fi
if [[ "$TODO_NEXT_ENABLED" == "true" ]]; then
  RULES_EXTRA+=$'\n- Re-read .repete/todo-next.md before acting. The moment you notice work outside this loop'"'"'s exit goal, append it there (one line: what + why + where). Do not chase it now.'
fi
if [[ "$LESSONS_ENABLED" == "true" ]]; then
  RULES_EXTRA+=$'\n- Consult the lessons catalog injected above. Read only the .repete/lessons/ cards whose tags match what you are about to do — do not bulk-read them all.'
  RULES_EXTRA+=$'\n- When you hit a mistake, dead-end, or a fix that did not work, write a lesson card to .repete/lessons/ in the template format: what you tried, what happened, the rule for next time.'
fi
PROTO+="$RULES_EXTRA"

# --- assemble re-inject: brief, [catalog], [constitution], protocol LAST ---
REINJECT="$PAYLOAD_BODY"
[[ -n "$CATALOG" ]] && REINJECT+=$'\n\n'"$CATALOG"
[[ -n "$CONSTITUTION" ]] && REINJECT+=$'\n\n--- project invariants (.repete/constitution.md) ---\n'"$CONSTITUTION"
REINJECT+=$'\n'"$PROTO"

SYSMSG="🔄 repete · phase ${PHASE} · iteration ${NEXT}"
if [[ "$AUTO_CAP_APPLIED" -eq 1 ]]; then
  SYSMSG+=$'\n🛟 repete: autonomous loop had no cap and no context budget — applied a safety max_iterations='"${AUTO_CAP_DEFAULT}"$' so a stuck mission can'"'"'t block Stop forever. Edit .repete/loop.local.md to raise or change it.'
fi
jq -n --arg r "$REINJECT" --arg m "$SYSMSG" \
  '{decision:"block", reason:$r, systemMessage:$m}'
exit 0
