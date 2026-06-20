---
description: Stop the active repete loop (state is preserved for review)
argument-hint:
allowed-tools: Read, Edit, Bash
---

# Cancel a repete loop

Deactivate the loop so the Stop hook stops intervening. Do NOT delete state — the user will
often want to inspect what the run produced.

1. If `.repete/loop.local.md` does not exist: report there is no loop to cancel; stop.
2. Set frontmatter `active: false` and `status: cancelled` in `.repete/loop.local.md` using
   Edit (operate only on the frontmatter block, never the body — and prefer Edit over `sed`
   so any free-text values are never mangled). Leave the body, `todo-next.md`, and
   `lessons/` intact.
3. Confirm to the user: loop cancelled at phase N / iteration M. Point out that
   `.repete/todo-next.md` (pending discoveries) and `.repete/lessons/` (what was learned)
   are preserved, and that `/repete` can start a fresh run that will read those lessons.

Mention they can delete `.repete/` manually if they want a clean slate.
