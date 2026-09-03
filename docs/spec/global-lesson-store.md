# Spec: v3 global lesson store — recurrence-gated promotion

> **Design record — proposed, not yet approved.** Nothing here ships; it is the
> evaluable design for issue #14. Locking direction BEFORE approval: the catalog
> stays METADATA-ONLY in every re-inject (constitution of the design); lessons
> stay self-reported; no hook-executed commands; fail-open.

Status: draft (issue #14, README v3 roadmap). Written 2026-09-03 from the existing
`severity`/`hits` ranking. Not implementable end-to-end today — the promotion
gate needs cross-project recurrence DATA that does not exist until more loops run
with lessons enabled; shipping the store before the data exists would promote on
noise. This spec is the evaluable design; implementation waits for N≥3 projects
with real lesson histories.

## Problem

Lessons are project-local (`.repete/lessons/`). A lesson that bites in three repos
— "BSD sed -i needs a suffix argument" — is rediscovered from scratch each time.
The cost of rediscovery is exactly what the lesson library exists to avoid.

## Design

### 1. Two stores, one reader

- **Local**: `.repete/lessons/` (today, unchanged — per-project cards).
- **Global**: `~/.config/cc-repete/lessons/` (new). Same card format, same
  frontmatter schema (`slug`, `tags`, `severity`, `hits`), plus `projects:` —
  the list of project roots that hit it.

The catalog builder (hook's lesson-catalog block) merges: **local wins on slug
collision** — a project's own phrasing of a lesson it hit is the one its agent
wrote for its own context, and local-only cards keep working offline. Merge is
read-time, never a copy: the global store is never bulk-imported into a project.

### 2. Promotion gate (recurrence, not judgment)

A local card is promoted (copied to global, `projects:` seeded with the source)
when the SAME slug-class lesson is hit in **N distinct projects** (default 3).

- "Same slug-class": normalized slug match (strip project prefixes / numbers:
  `001-foo-trap` and `014-foo-trap` → `foo-trap`). Exact-slug-only would let
  trivial numbering differences defeat the gate.
- The hit is recorded where the card is READ, not where written: a project that
  reads a global card and hits the lesson again bumps `hits` and appends its root
  to `projects:` (idempotent per project).
- Gate evaluation runs at teardown/done — never mid-loop, never on the Stop path
  (the Stop path gains no new I/O; the loop engine's latency budget stays as is).

### 3. What the re-inject sees (unchanged surface)

The catalog line for a promoted lesson carries a `↗` marker and its (capped)
cross-project hit count: `↗ bsd-sed-in-place-suffix [portability] sev:high
hits:7 projects:3`. Still one line. Still capped by `lesson_catalog_cap`.
**No lesson bodies, ever, in any re-inject** — the global store changes where
metadata comes from, not what the loop carries. Injecting global bodies every
iteration would export one project's context rot to all of them.

### 4. Failure directions

- Global dir unreadable/absent → local-only catalog (fail-open, warn once per
  session at most — quieter than the no-jq marker; this is an enhancement, not
  a safety mechanism).
- Promotion write fails → stay local, warn at teardown (the loop already ended;
  nothing traps).
- A malicious/typo'd global card → worst case a wrong one-line hint. The
  metadata-only rule is the containment: the loop never executes lesson content.

## Acceptance (from issue #14, made testable)

- [ ] Global store path + promotion rule documented here (this file IS that
  deliverable) — pinned by a couplings-table row when implemented
- [ ] Catalog builder merges local + global; local wins on slug collision (ck:
  both cards exist, rendered line shows local's text)
- [ ] Promotion gate: N distinct `projects:` roots; N default 3; idempotent
  per-project (ck via a promotion helper's unit test, NOT on the Stop path)
- [ ] No lesson bodies in any re-inject — golden SHA unchanged by the existence
  of a global store with content (ck: reason contains no card body text)
- [ ] Unreadable global dir → local-only, loop unaffected (ck)

## Out of scope

- Cross-machine sync of the global store (dotfiles/gist — user's business).
- Demoting/deleting global cards — manual, by hand, until real usage shows a
  need; `hits` decay is deliberately absent (a lesson that stopped biting is
  cheap to carry at one line).
- Server-side anything. The store is a directory.
