#!/usr/bin/env bash
# Reads stdin (session JSON) but repete state lives on disk — no stdin fields needed.
cat > /dev/null

LOOP="$CLAUDE_PLUGIN_ROOT/.repete/loop.local.md"
[[ -f "$LOOP" ]] || exit 0

active=$(awk '/^active:/{print $2}' "$LOOP")
[[ "$active" == "true" ]] || exit 0

iter=$(awk '/^iteration:/{print $2}' "$LOOP")
max=$(awk '/^max_iterations:/{print $2}' "$LOOP")

if [[ "$max" -gt 0 ]]; then
  printf 'rp[%s/%s]' "$iter" "$max"
else
  printf 'rp[%s]' "$iter"
fi
