<!--
  .repete/handoff.md — in-flight snapshot written at a context checkpoint.

  When the transcript crosses context_budget_lines, the Stop hook spends one
  turn having the agent write this file BEFORE the conversation is /clear-ed,
  then yields. /repete-continue reads it first on rehydrate, so the in-flight
  state that is NOT yet on disk survives the wipe. The agent overwrites this
  file each cycle; you normally never edit it by hand.

  Keep it tight — under ~30 lines. This captures the DELTA not already in the
  loop body / todo-next / lessons / commits; it is not a place to re-summarize
  durable facts (those get re-read losslessly on rehydrate). Fill the four
  sections below.
-->

## Done this stretch

<what was just finished, with file paths / commit refs>

## In flight

<what is half-done right now and exactly where you left off>

## Next concrete step

<the single next action to take after the reload>

## Open questions & risks

<anything unresolved the next session must know>
