#!/usr/bin/env bash
# Shared helpers for the cc-repete smoke harness. Source this from each suite.
# Drives the REAL hooks/stop-hook.sh against synthetic state + transcripts in a
# mktemp fixtures root (outside the repo — the repo's own files contain literal
# sentinel strings that would corrupt detection tests).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/stop-hook.sh"
ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t repete-smoke)"
PASS=0; FAIL=0

mkstate() { # dir status active iter max ctx goal session
  local d="$1"; [[ "$d" == "$ROOT"/* ]] || { echo "refusing mkstate outside ROOT: $d" >&2; return 1; }
  rm -rf "$d"; mkdir -p "$d/.repete/lessons"
  cat > "$d/.repete/loop.local.md" <<EOF
---
active: $3
phase: 2
iteration: $4
session_id: $8
max_iterations: $5
context_budget_lines: $6
mission_goal: $7
lesson_catalog_cap: 8
status: $2
started_at: "x"
---
# Current loop payload
BODY-LINE-ONE
---
this is a horizontal rule inside body, must survive
final body line
EOF
}

mktrans() { # file text
  local f="$1"; shift
  : > "$f"
  printf '%s\n' "$(jq -nc --arg t "user msg" '{message:{role:"user",content:[{type:"text",text:$t}]}}')" >> "$f"
  printf '%s\n' "$(jq -nc --arg t "$1" '{message:{role:"assistant",content:[{type:"text",text:$t}]}}')" >> "$f"
}

mkcard() { # dir slug tags severity hits
  # Mirrors the REAL shipped lesson-card template: a leading <!-- --> comment
  # block before the frontmatter AND inline "# comment" prose on the tags /
  # severity / hits lines. This shape is what card_field must survive (B1) —
  # a clean-value fixture would false-green past the comment-strip bug.
  local d="$1" slug="$2" tags="$3" sev="$4" hits="$5"
  cat > "$d/.repete/lessons/$slug.md" <<EOF
<!--
  One lesson per file. Name NNN-short-slug.md.
-->
---
slug: $slug
tags: [$tags]   # used to decide which lessons to surface into a loop
severity: $sev       # how badly it bit
hits: $hits                              # increment each time this recurs
created: 2026-06-20
---

**Situation:** test card $slug
**Rule:** do the thing
EOF
}

runhook() { # projectdir transcriptpath sessionid
  local d="$1" t="$2" s="$3" input
  input="$(jq -nc --arg tp "$t" --arg sid "$s" '{transcript_path:$tp, session_id:$sid}')"
  OUT="$(CLAUDE_PROJECT_DIR="$d" printf '%s' "$input" | CLAUDE_PROJECT_DIR="$d" bash "$HOOK" 2>/dev/null)"
  RC=$?
}

getfm() { # dir key
  awk 'BEGIN{f=0}/^---[[:space:]]*$/{f++;next}f==1{print}f>=2{exit}' "$1/.repete/loop.local.md" \
    | grep "^$2:" | head -1 | sed "s/^$2:[[:space:]]*//"
}

assert() { # label rc
  if [[ "$2" -eq 0 ]]; then echo "  PASS: $1"; PASS=$((PASS+1));
  else echo "  FAIL: $1"; echo "        OUT=$OUT"; FAIL=$((FAIL+1)); fi
}

summary() {
  echo; echo "==== RESULT: $PASS passed, $FAIL failed ===="
  [[ "$FAIL" -eq 0 ]]
}
