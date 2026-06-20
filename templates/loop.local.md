---
active: true
phase: 1
iteration: 1
session_id: ""
max_iterations: 0
context_budget_lines: 2500
lesson_catalog_cap: 8
mission_goal: ""
status: running
started_at: ""
---
# Current loop payload

> This body is what gets re-fed to the agent each iteration. It is the CURRENT
> loop's working brief — narrower than the mission. At a checkpoint the agent
> proposes the next version of this body in <repete-checkpoint>, and
> /repete-continue promotes the approved version here.

## This loop's exit goal

<the concrete, checkable thing THIS loop must achieve before it checkpoints>

## Working brief

<what to do this loop, in priority order. Reference real files/paths.>

## Known traps

The hook injects a lessons **catalog** (slug · tags · severity · hits) into every
iteration automatically. Consult it and `Read` only the relevant `.repete/lessons/`
cards on demand — do not paste card contents here. This section stays a pointer; it
must never hold card bodies (that would re-inject them every iteration).
