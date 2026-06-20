# repete v2 — Memory Layering Design

**Date:** 2026-06-20
**Status:** Proposed (awaiting approval)
**Supersedes roadmap slot:** This becomes v2, ahead of the previously-planned "mission as N named phases" (which slips to v3). Rationale: context rot is the live architectural risk surfaced by the first live run; named-phases is a feature. Rot wins the queue.

## 1. Problem

After the first live run of repete v0.1.0, the architectural critique converged on one root issue and one explicit feature request:

1. **Single-session context rot.** The loop re-injects into a live conversation via the Stop hook's `decision:block` + `reason`. Context accumulates across iterations — prior tool calls, dead-ends, failed attempts. The research brief (see §8) confirms this degrades reasoning at **4–32K effective tokens** for reasoning-heavy tasks (NoLiMa), far below the 200K window, and that a loop's own accumulated dead-ends are the *worst-case* filler (distractors collapsed effective context 8× in controlled tests).

2. **Static memory request.** The user wants a way to inject **frozen, user-authored invariants** (don't-touch dirs, keep API stable, run tests with X, commit conventions) alongside the evolving loop payload. Today these sit passively in `MISSION.md`'s Constraints section and never ride the re-inject.

### Architectural constraint (confirmed, load-bearing)

A Claude Code Stop hook **cannot** clear/reset conversation context, trigger compaction, or spawn a fresh-context turn. Its only outputs are `decision:block`+`reason` (re-inject same session), `continue`, `systemMessage`, and `hookSpecificOutput.additionalContext`. True fresh-process iteration requires an **external runner** (`while` loop calling bare `claude -p`), which is a *second engine*, not a hook knob.

**Decision:** repete stays on the **hook spine** (single session, re-inject). We mitigate rot with disciplined memory layering, not a process restart. The external runner is **explicitly out of scope** — deferred to a possible v3, gated on real unsupervised long-haul usage and on-domain evidence we do not currently have. The disk-backed layered state this design introduces is the runner's prerequisite, so deferring it costs nothing: same substrate, two possible readers.

### Mission profile this serves

**Supervised, evolving, single-track.** Human at the wheel, missions checkpoint within tens of K accumulated tokens. This matches every locked v1 decision (human-gated checkpoints, rot-as-checkpoint, interactive commands). The reset valve (`context_budget` → pause → `/clear` → `/repete-continue`) already handles rot at these lengths; this design makes the *between-reset* context cleaner and the frozen layer real.

## 2. The four memory layers

The validated architecture (MemGPT split, corroborated by Reflexion/Voyager — see §8) is: a short frozen constitution + evolving disk-backed working memory + *retrieved* (not inject-all) lessons. Mapped to repete:

| Layer | Home | Delivery | Mutability | Owner |
|---|---|---|---|---|
| **Engine protocol** | `templates/protocol.md` (shipped with plugin) | re-injected **last** in `reason` | frozen, **hook-versioned** | repete |
| **User constitution** | `.repete/constitution.md` | re-injected, **before** protocol | frozen per run, user-authored | user |
| **Evolving brief** | `.repete/loop.local.md` body | re-injected (exists in v1) | evolves at checkpoints | agent (user-approved) |
| **Lessons** | `.repete/lessons/*.md` | **catalog** (metadata) injected; **content** agent-retrieved | append + dedup | agent |

The governing invariant that sets the boundary between layers 1 and 2:

> **Whatever can desync from the hook's actual control-flow behavior must not be user-editable.**

The engine protocol *describes the hook's own sentinel/exit semantics*. If a user could edit it, two failures follow: (a) they delete the done-guard wording and degrade safety silently; (b) every protocol upgrade shipped with a new hook must reconcile against N divergent user copies, and the protocol text drifts out of sync with the code that actually enforces it. So the protocol is welded to the hook — shipped in `templates/` (hook-versioned), never copied into `.repete/` (project-versioned).

The user constitution is the inverse: it describes *the user's project*, not the engine, so it lives in project state and the user owns it fully.

## 3. Re-inject assembly and ordering

The hook builds the `reason` string from four parts, **in this order**:

```
1. Evolving brief        (loop.local.md body — the "what to do now")
2. Lessons catalog       (one metadata line per card, ranked + capped)
3. User constitution     (.repete/constitution.md verbatim, if present)
4. Engine protocol       (templates/protocol.md, or inline fallback)
```

**Why this order — recency.** The "Lost in the Middle" U-curve and the recency-washout findings (§8) say instructions near the *end* of context are followed more reliably than those buried mid-context, and that early-position instructions decay over a long run. The two **frozen, must-follow** layers (constitution = user's hard rules; protocol = the exit-sentinel semantics) therefore go **last**. The evolving brief leads because it's the volatile working payload; lessons sit in the middle because they're advisory.

This is also a deliberate formalization of an accident: v1's hardcoded RULES heredoc already appends last (`stop-hook.sh:148`, `REINJECT="$PAYLOAD_BODY$RULES"`). We keep that placement and make it intentional.

**Re-injection is measured to help, not bloat.** Repeating a short, conflict-free instruction block each iteration won 47/70 controlled tests with 0 losses (§8). The danger is rule *count and mutual conflict*, not repetition — so both frozen layers must stay short and internally consistent. The spec caps this (§7).

## 4. Engine protocol extraction (`templates/protocol.md`)

The hardcoded heredoc at `stop-hook.sh:137-146` moves to `${CLAUDE_PLUGIN_ROOT}/templates/protocol.md`. Content is the same protocol, with two edits:

- The "re-read the cards in `.repete/lessons/`" rule is **replaced** by the catalog-consult rule (§5).
- A line is added pointing the agent at `.repete/constitution.md` as the user's hard invariants (so the agent knows that layer is authoritative).

The protocol template uses `${PHASE}` / `${NEXT}` placeholders that the hook substitutes at assembly time (same two values interpolated in the v1 heredoc).

### Fail-functional fallback

The v1 hook is self-contained — it has **no** hard dependency on `templates/` existing at runtime. Extracting the protocol to a file introduces one. To preserve the existing fail-open philosophy (no `jq` → allow stop rather than trap), the hook **must not** lose its protocol if the file is unreadable:

> If `templates/protocol.md` cannot be read (missing, botched install, partial checkout), the hook falls back to a **minimal inline protocol string** baked into the hook itself — enough to keep the two sentinels and the core rules alive. Fail-functional, matching fail-open jq.

The inline fallback is the irreducible safety core: the two sentinel rules (checkpoint when loop goal met; done only when mission goal verifiably true, exact string) plus "work from files, not memory." The richer prose (todo-next harvest phrasing, lesson reflection guidance) lives only in the template; losing it degrades quality, not safety.

## 5. Lessons: catalog injection + agent retrieval

### The constraint that kills "inject top-K cards"

The hook injects a *string*, not files-into-context. "Retrieve top-K lessons and inject them" would mean bash concatenating card **bodies** (situation/tried/outcome/rule prose) into `reason` every Stop — re-injecting exactly the rot-heavy content the research says to evict, and growing the re-inject by one prose block per surfaced card.

### The design

**Hook injects a catalog, never content.**

On each Stop, the hook scans `.repete/lessons/*.md` (excluding `_TEMPLATE.md`) and emits **one line per card** from frontmatter only:

```
Known lessons (consult before acting; Read only the relevant ones):
  003-jest-esm-mock      [jest,esm,mock]        high   hits:4
  007-flaky-timeout      [async,test]           medium hits:2
  001-perl-quoting       [hook,shell]           low    hits:1
  … +12 more — grep .repete/lessons/
```

- **Ranking:** `severity` (high→low) then `hits` (desc). Highest-impact, most-recurrent lessons surface.
- **Cap:** default **8** lines, with a `+M more — grep .repete/lessons/` overflow note. Configurable via a new `lesson_catalog_cap` frontmatter key (0 = uncapped, for small projects).
- **Size:** ~30 chars/line → an 8-line catalog is ~250 chars, **bounded regardless of library size**. 200 cards still produce 8 lines + overflow.

**Agent retrieves content with its own judgment.** The protocol rule becomes: *"Consult the lessons catalog above. `Read` only the cards whose tags match what you're about to do."* The agent knows the current sub-task; a bash tag-matcher does not. This is retrieval-as-tool-call (Voyager/MemGPT done right), not payload force-feeding.

**Catalog is built fresh each Stop, not a maintained `INDEX.md`.** Always current, zero drift. Parsing one frontmatter line across N files per Stop is cheap.

### Why soft retrieval is acceptable here

"Consult the catalog" is a *soft* rule (the agent could ignore it). That's correct: lessons are **advisory**, unlike the done-guard which is safety-critical. We spend "hard" enforcement only on the sentinels (which live in code, in the hook's three-way decision — unchanged by this design). Advisory layers get advisory delivery.

### Decoupling achieved

This is the only design where **lesson count is decoupled from re-inject size**. The measured rot source — pulling every card into context each iteration — is eliminated: the catalog grows one *line* per card, and card *bodies* enter context only on demand, only when relevant.

## 6. Changes by file

### New files
- `templates/protocol.md` — extracted engine protocol (§4), with `${PHASE}`/`${NEXT}` placeholders.
- `templates/constitution.md` — a commented starter the `/repete` scaffold copies to `.repete/constitution.md`; documents what belongs here (hard invariants) vs. what belongs in the evolving brief.

### Modified files
- `hooks/stop-hook.sh`:
  - Replace the `RULES` heredoc (137-146) with: read `templates/protocol.md` (fallback to inline core); substitute `${PHASE}`/`${NEXT}`.
  - Add constitution read: `.repete/constitution.md` verbatim if present, else skip silently.
  - Add catalog builder: scan `.repete/lessons/`, parse frontmatter, rank, cap, format.
  - Assemble `reason` in the §3 order: brief, catalog, constitution, protocol.
  - Read `lesson_catalog_cap` frontmatter (default 8).
- `commands/repete.md` (scaffold step 2): create `.repete/constitution.md` from the template; prompt the user (briefly) for any known hard invariants to seed it, or leave the commented starter. Add `lesson_catalog_cap` to the frontmatter it writes.
- `templates/loop.local.md`: add `lesson_catalog_cap: 8` to frontmatter.
- `commands/repete-continue.md`: the `paused-context` rehydrate path should read `.repete/constitution.md` too (it's part of the boot manifest). The checkpoint path's "refresh Known traps from lessons" step (currently inject-all-flavored) aligns with the catalog model — note that lessons are now agent-retrieved, not bulk-copied into the body.
- `commands/repete-status.md`: already reports lesson count + top slugs — extend to show the catalog as the hook would render it (so the user previews what the loop sees).

### Unchanged (explicitly)
- The hook's **three-way decision** (done / checkpoint / continue) and both safety yields (max_iter, context_budget). This design touches only what goes *into* the re-inject, not the control flow that decides *whether* to re-inject.
- The two sentinels and their exact-match/checkpoint-wins semantics.
- `context_budget_lines` (the `wc -l` vs `wc -c` fix and no-progress detection are separate, smaller improvements — **not** in this spec; tracked for a later pass to keep this one focused on layering).

## 7. Constraints / guardrails

- **Frozen layers stay short and conflict-free.** Constitution + protocol combined should stay well under ~40 lines. The scaffold and `/repete-status` should warn if `constitution.md` grows large (rule-count is the measured adherence killer, not position). Soft warning, not a hard limit.
- **No card bodies in the re-inject, ever.** The catalog is metadata-only by construction.
- **Fail-functional, not fail-silent.** Missing protocol template → inline fallback (loop continues). Missing/empty constitution → skip silently (it's optional). Missing lessons dir → empty catalog, no error.
- **Catalog cap is bounded by default.** Uncapped (0) is opt-in for small projects only.

## 8. Evidence base (research brief summary)

Full brief in conversation; load-bearing findings, tagged [MEASURED]/[REPORTED]/[INFERRED]:

- **Rot is real and bites early.** Effective reasoning context collapses to 4–32K tokens on a 200K window (NoLiMa, ICML 2025) [MEASURED]. Gradient, not cliff (Chroma, Anthropic) [REPORTED].
- **Accumulated dead-ends are the worst filler.** Topically-adjacent distractors collapsed effective context 8× while base ability held (NoLiMa distractor condition) [MEASURED]. Self-generated *contradictory* prior content — the exact repete failure mode — is **not directly benchmarked**; supported by analogy [INFERRED]. *This is the one un-measured gap; it argues for the architecture but the magnitude is unknown.*
- **Restart/reconsolidate beats continue** (Lost-in-Conversation: 39% multi-turn drop; ERGO reset: +56.6%) [MEASURED] — but off-domain (general multi-turn, not coding). This validates the *frozen-layer + clean-state* direction; it does **not** justify building the runner now on this evidence.
- **Summarization is a rot vector** (LOCOMO: raw beats summaries; Anthropic concedes lossiness) [MEASURED]. → lossless disk re-read, not in-context summarize. repete's `/clear`+rehydrate-from-disk already follows this.
- **MemGPT split is the validated architecture** (frozen instructions + paged working memory) [REPORTED]. Immutability must be harness-enforced — the pattern doesn't enforce it. → §2 boundary invariant.
- **Retrieve lessons, don't inject-all** (Reflexion: distilled lesson +8% over raw trajectory; Voyager: top-K retrieval) [MEASURED]. → §5 catalog + on-demand read.
- **Re-injecting a short static constitution helps and is nearly free** (Google prompt-repetition: 47/70 wins, 0 losses) [MEASURED]. Danger is rule count/conflict, not repetition. → §3 last-position, §7 short-and-conflict-free.

## 9. Out of scope (this spec)

- External fresh-process runner (possible v3, evidence-gated).
- `wc -l` → `wc -c` context-budget fix; no-progress/thrash detection; missing-`jq` one-time warning. Separate small-improvements pass.
- Cross-project / global lessons (`~/.claude/repete/`), recurrence-gated promotion, consolidation pass — the original v3.
- Mission as N named phases — the original v2, now v3+.

## 10. Open questions for reviewer

1. **Catalog cap default = 8.** Right number, or do you want it lower (tighter) / higher? (Bounded either way.)
2. **Constitution seeding at `/repete` setup.** Prompt the user for invariants interactively, or always lay down the commented starter and let them fill it? (Leaning: lay down starter, *offer* to seed from their stated constraints, don't force a prompt.)
3. **Should `MISSION.md`'s Constraints section migrate into `constitution.md`?** They overlap. Options: (a) leave both, constitution is the re-injected one; (b) constitution *replaces* the Constraints section; (c) constitution re-injects, Constraints stays as human-readable mission doc. (Leaning: c — different audiences, MISSION.md is for the human, constitution is for the loop.)
