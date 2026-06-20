---
name: designing-autonomous-loops
description: >-
  Decide whether and how to run an agent in an autonomous loop — repete (single-session
  re-inject) vs. ralph (fresh process per iteration) vs. a one-shot, plus how to fight
  context rot with memory layering. Use this whenever the user is weighing "should I loop
  this", asks about autonomous/agentic loops, iteration harnesses, context rot, a long
  unattended run, a ralph loop, set-and-forget agents, or how to keep a long agent run from
  degrading — even if they don't name a specific tool. Reach for this before architecting a
  loop, so the choice is grounded in how context rot actually behaves rather than vibes.
compatibility: Conceptual guidance; pairs with the running-repete-loops skill for operating cc-repete specifically.
---

# Designing autonomous loops

An autonomous loop runs an agent over and over toward a goal with little or no human input
between iterations. The central problem every loop design fights is **context rot**: the
agent's reasoning degrades as its context fills with accumulated turns, tool output, and — the
worst offender — its own dead-ends. This skill is the decision guide: when to loop at all,
which loop architecture fits, and how to layer memory so the loop stays sharp.

The guidance below is grounded in measured findings, not intuition. Where a claim rests on
evidence, it's flagged; where it's an inference or off-domain extrapolation, that's flagged too,
because designing on a misattributed number is how you build the wrong harness.

## First decision: should this even be a loop?

Loops earn their complexity when the task is **iterative, long, and has a checkable end state**.
They're the wrong tool when:

- **The task is one-shot.** If a single well-scoped agent turn does it, a loop just adds a Stop
  hook, state files, and failure modes. Don't loop a thing that doesn't iterate.
- **There's no verifiable completion state.** A loop with a vibe goal ("make it better") can't
  terminate honestly — it runs to its cap or fakes done. If you can't name the world-state that
  means "finished", you're not ready to loop; you're ready to *plan*.
- **Every iteration needs human judgment anyway.** If a human must look at each step, the loop's
  unattended-iteration advantage evaporates and you're just adding ceremony to a conversation.

Loops shine for: migrations (N files, same transform), test-until-green, broad sweeps/audits,
"keep going until this command exits 0" — work that's mechanical to verify but long to do.

## Second decision: single-session vs. fresh-process

This is the architecture fork, and it's a real tradeoff, not a clean win either way.

**Single-session re-inject (repete's model).** A Stop hook blocks the stop and re-injects the
payload into the *same* conversation. Context accumulates across iterations. Cheap to run,
native to an interactive session, supports human-gated checkpoints — but it's exposed to rot,
because the agent at iteration 8 is reasoning over a window full of iterations 1–7's dead-ends.

**Fresh-process (ralph's model).** An external shell loop (`while :; do claude -p < prompt; done`)
starts a clean process each iteration; the only state that survives is on disk, which the agent
re-reads. **Structurally immune to rot** — iteration 30 is as pristine as iteration 1 — but it
loses the interactive session, the human-at-the-boundary gating is awkward, and it needs an
external runner babysitting the loop.

A hard constraint that decides reachability: **a Claude Code Stop hook cannot clear its own
context, trigger compaction, or spawn a fresh process.** Its only lever is re-inject-into-same-
session. So "auto-reset every N iterations from inside the hook" is not a thing — true fresh-
process means an external runner, which is a *second engine*, not a config knob. [MEASURED: hook
output fields are `decision/reason/continue/systemMessage/hookSpecificOutput` — none reset context.]

Pick by profile:

| Profile | Use | Why |
| --- | --- | --- |
| Supervised, evolving, single-track, checkpoints within tens of K tokens | **single-session** (repete) | Rot is mitigable at these lengths; you get checkpoints + an evolving payload + native UX. |
| Unsupervised, long-haul, hundreds of K tokens, rot-immunity non-negotiable | **fresh-process** (ralph) | Only structural immunity survives a set-and-walk-away grind. |
| Genuinely both | single-session now, **build disk-backed state** so a runner is reachable later | The layered disk state is the runner's prerequisite; you don't have to choose up front. |

The decisive question is **supervision**, not preference: if a human is present at boundaries,
single-session's soft mitigations are enough and you keep the richer UX. If nobody's watching
for hundreds of K tokens, only the fresh process holds up.

## How context rot actually behaves (so you design for the real curve)

Designing a loop without knowing the rot curve is how budgets get set wrong. The measured shape:

- **Effective context ≪ advertised window.** "Effective context" (length retaining ≥85% of the
  short-context score) collapses far below the max. On strict reasoning tests, frontier models'
  effective context lands around **4–32K tokens** on a 200K window. [MEASURED: NoLiMa, RULER.]
  Design for that floor, not the sticker number.
- **It's a gradient, not a cliff.** Degradation is gradual and starts early — there's no single
  token count where it falls off. [REPORTED: Chroma, Anthropic.] So "stay under the limit" is the
  wrong mental model; "minimize accumulated junk continuously" is the right one.
- **Dead-ends are the poison, not raw length.** Topically-adjacent distractors collapsed effective
  context ~8× while leaving base ability almost intact. [MEASURED: NoLiMa distractor condition.]
  A loop's own failed attempts are exactly this worst case — plausible-but-wrong neighbors. The
  most relevant variant (a model's *own contradictory* prior reasoning) isn't directly
  benchmarked [INFERRED], but the analogy is strong: evict dead-ends aggressively.
- **Restart beats continue.** A clean restart that re-reads consolidated state outperforms
  continuing a degraded thread; explicit context resets have shown large gains. [MEASURED:
  Lost-in-Conversation 39% multi-turn drop; ERGO reset +56.6% — but off-domain, general
  multi-turn, not coding. Treat the *direction* as solid, the magnitude as untransferred.]
- **Summarization is itself a rot vector.** Summaries lose subtle context whose importance only
  shows up later; raw retrieved facts beat summaries. [MEASURED: LOCOMO; Anthropic concedes
  lossiness.] So prefer **lossless re-read from disk** over in-context summarize-and-compress.

The practical rule of thumb (moderate confidence, partly extrapolated): for reasoning-heavy
work, force a rehydrate-from-disk well before ~50% of the window — roughly the **30–50K
accumulated-token** band on a 200K model — and earlier if the context is filling with failed
attempts rather than clean progress. The trigger that matters is *distractor accumulation*, not
raw token count; a loop eating its own dead-ends crosses the danger line faster than the token
counter implies.

## Memory layering: the architecture that survives long runs

The validated pattern (MemGPT split, corroborated by Reflexion and Voyager) separates **frozen**
from **evolving** memory and **retrieves** rather than injects-everything:

1. **A short, frozen, conflict-free constitution.** Immutable invariants, always present.
   Re-injecting a *small* static instruction block every iteration **helps and is nearly free**
   [MEASURED: prompt-repetition 47/70 wins, 0 losses]. The danger is rule *count and conflict*,
   not repetition — so keep it tight. Enforce immutability in your harness; the pattern doesn't
   do it for you.
2. **Evolving working memory on disk.** The current task payload, updated at each boundary.
   Persist it to disk and **re-read** it — lossless retrieval beats carrying a degrading copy in
   context, and beats summarizing it.
3. **A retrieved lesson library, not an injected one.** Store *distilled* reflections (the rule,
   not the transcript) [MEASURED: Reflexion +8% over raw traces], and surface them by retrieval —
   inject a lightweight catalog, pull full content on demand [Voyager top-K]. Injecting every
   lesson each iteration recreates the exact rot you're fighting; a metadata catalog keeps lesson
   *count* decoupled from re-inject *size*.

Ordering note for re-injected layers: put the frozen, must-follow layers **last**. At the scale
of a short re-inject block, position effects are negligible, but last-position is never worse and
keeps the binding rules out from under the volatile payload. (Don't justify this with the
200K-window "lost in the middle" curve — that doesn't transfer to a 40-line block; the reason is
simply "don't bury the must-follow rules.")

## Putting it together — a design checklist

1. **Is it a loop?** Iterative + long + checkable end state. If not, plan or one-shot instead.
2. **Name the verifiable done-state.** A world-fact the agent can check and echo. No vibe goals.
3. **Supervised or not?** → single-session (repete) vs. fresh-process (ralph). Decide on
   supervision, not taste.
4. **Layer the memory.** Frozen constitution (short, last) + evolving brief (disk, re-read) +
   distilled lessons (retrieved via catalog, not injected).
5. **Set the rot valve.** Plan to rehydrate-from-disk in the ~30–50K-token band, earlier if
   dead-ends are piling up. Lossless re-read, never summarize-and-continue.
6. **Mitigation is soft on a hook spine.** Single-session leans on prompt rules + the human at
   checkpoints; if the real workload drifts to unsupervised hundreds-of-K runs, that's the
   signal to graduate to a fresh-process runner — a decision to make on your own measured
   evidence, not on the off-domain numbers above.

For operating cc-repete specifically against this design, use the **running-repete-loops** skill.
