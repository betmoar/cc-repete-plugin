# Mission

> The north star for this repete run. The loop re-reads this every iteration and
> re-checks it at every transition. Keep it short, concrete, and verifiable.

## Mission goal (exit condition)

<!--
  The EXACT string the agent must echo inside <repete-done>...</repete-done> to end
  the whole run. Must be unambiguously checkable — a state of the world, not a vibe.
  This same string is stored as `mission_goal` in loop.local.md; keep them identical.
-->

GOAL: <one-line, verifiable completion statement>

## Why / definition of done

- <what "done" actually means — the checks that prove the goal is true>
- <e.g. "all tests in suite X green", "endpoint Y returns Z", "doc W covers cases A–C">

## Out of scope (do NOT do these)

- <things that will tempt the loop but belong to a later run>
- Park out-of-scope finds in `.repete/todo-next.md` — but ONLY if `todo_next_enabled: true`
  in loop.local.md (the file and its journaling rule don't exist otherwise; the finds would
  vanish). Otherwise name them at the checkpoint for the human to triage.

## Constraints

Hard invariants live in `.repete/constitution.md` (single source — re-injected into
the loop each iteration). Edit that file, not this section.
