# Context rot — the evidence, and the architecture that follows

Read this when setting `context_budget_lines`, when a user asks *why* the loop stops to
`/clear`, or when designing a loop harness that isn't repete. The parent skill's decisions
rest on these findings; keeping them here means the numbers stay checkable instead of
becoming folklore.

Every claim below is flagged by evidence class, because designing a budget on a misattributed
number is how you build the wrong harness:

- **[MEASURED]** — a benchmark result in the cited work.
- **[REPORTED]** — stated by the source without a public benchmark behind it.
- **[INFERRED]** — our extrapolation. Treat the direction as usable, the magnitude as not.

## How rot actually behaves

- **Effective context ≪ advertised window.** "Effective context" — the length still retaining
  ≥85% of the short-context score — collapses far below the maximum. On strict reasoning
  tests, frontier models land around **4–32K tokens on a 200K window**. [MEASURED: NoLiMa,
  RULER.] Design against that floor, not the sticker number.
- **It's a gradient, not a cliff.** Degradation is gradual and starts early; there is no token
  count where quality falls off. [REPORTED: Chroma, Anthropic.] So "stay under the limit" is
  the wrong mental model — "minimize accumulated junk continuously" is the right one.
- **Dead-ends are the poison, not raw length.** Topically-adjacent distractors collapsed
  effective context ~8× while leaving base ability nearly intact. [MEASURED: NoLiMa distractor
  condition.] A loop's own failed attempts are precisely this worst case: plausible-but-wrong
  neighbors. The most relevant variant — a model's *own contradictory* prior reasoning — isn't
  directly benchmarked [INFERRED], but the analogy is strong enough to act on: evict
  dead-ends aggressively.
- **Restart beats continue.** A clean restart that re-reads consolidated state outperforms
  continuing a degraded thread. [MEASURED: Lost-in-Conversation, a 39% multi-turn drop; ERGO,
  +56.6% from explicit resets — but both off-domain, general multi-turn rather than coding.
  Direction solid, magnitude untransferred.]
- **Summarization is itself a rot vector.** Summaries lose subtle context whose importance
  only surfaces later; raw retrieved facts beat summaries. [MEASURED: LOCOMO; Anthropic
  concedes lossiness.] Prefer **lossless re-read from disk** over in-context
  summarize-and-compress.

### Two things that both look like "writing a summary"

Only one is the rot vector, and conflating them is why people distrust repete's handoff step:

- **Summarize-and-continue** — compress the window and keep reasoning in the *same degraded
  thread*. This is the discouraged move. It prevents nothing and poisons the window, and it
  never substitutes for re-reading durable facts.
- **A handoff snapshot** — a tiny capture of *uncommitted in-flight delta* (what's half-done,
  plus the single next step) written immediately before a clean restart, so that delta isn't
  lost entirely across the context wipe. It supplements the restart's lossless re-read and is
  thrown away once the durable facts are re-read.

repete's `paused-context` two-step is the second thing: one turn writing `.repete/handoff.md`,
then a pause for `/clear`, then a rehydrate that reads from disk. It is deliberately not the
first.

## The practical threshold

For reasoning-heavy work, force a rehydrate-from-disk well before ~50% of the window —
roughly the **30–50K accumulated-token band on a 200K model** — and earlier when the context
is filling with failed attempts rather than clean progress. Moderate confidence, partly
extrapolated.

The trigger that matters is **distractor accumulation, not raw token count**. A loop eating
its own dead-ends crosses the danger line faster than the counter implies. This is also why
`context_budget_lines` counts transcript lines rather than tokens: it's a deliberately coarse
proxy, and it's the reason the parent skill tells you to checkpoint by hand when output
quality degrades before the budget trips.

## Memory layering — the architecture that survives long runs

The validated pattern (MemGPT's split, corroborated by Reflexion and Voyager) separates
**frozen** from **evolving** memory and **retrieves** rather than injects-everything. repete
implements exactly this; the mapping is in the parent skill's four-layer table.

1. **A short, frozen, conflict-free constitution.** Immutable invariants, always present.
   Re-injecting a *small* static instruction block every iteration **helps and is nearly
   free** [MEASURED: prompt-repetition, 47/70 wins, 0 losses]. The danger is rule *count and
   conflict*, not repetition — so keep it tight. Your harness must enforce immutability; the
   pattern doesn't do it for you.
2. **Evolving working memory on disk.** The current task payload, updated at each boundary.
   Persist and **re-read** it: lossless retrieval beats both carrying a degrading copy in
   context and summarizing it. Externalize *continuously*, not only at boundaries — the more
   working state already on disk, the less a restart loses. What hasn't landed on disk at
   reset time is the only thing a handoff snapshot needs to carry.
3. **A retrieved lesson library, not an injected one.** Store *distilled* reflections — the
   rule, not the transcript [MEASURED: Reflexion, +8% over raw traces] — and surface them by
   retrieval: inject a lightweight catalog, pull full content on demand [Voyager top-K].
   Injecting every lesson each iteration recreates the exact rot you're fighting; a metadata
   catalog decouples lesson *count* from re-inject *size*.

**Ordering.** Put the frozen, must-follow layers **last**. At the scale of a short re-inject
block, position effects are negligible, but last is never worse and keeps the binding rules
out from under the volatile payload. Don't justify this with the 200K-window
"lost in the middle" curve — that doesn't transfer to a 40-line block. The reason is simply:
don't bury the must-follow rules.

## Design checklist for a loop harness

1. **Is it a loop?** Iterative + long + checkable end state. Otherwise plan, or one-shot.
2. **Name the verifiable done-state.** A world-fact the agent can check and echo.
3. **Supervised or not?** → single-session vs. fresh-process. Decide on supervision, not taste.
4. **Layer the memory.** Frozen constitution (short, last) + evolving brief (disk, re-read) +
   distilled lessons (retrieved via catalog).
5. **Set the rot valve.** Rehydrate-from-disk in the ~30–50K band, earlier when dead-ends pile
   up. Lossless re-read, never summarize-and-continue — but do snapshot the uncommitted delta
   right before the reset. Treat that snapshot as best-effort: when the write lands the restart
   is lossless; when it doesn't, durable on-disk state still gives a clean one. That asymmetry
   is why you externalize progress every iteration rather than only at the reset.
6. **Know that mitigation is soft on a hook spine.** Single-session leans on prompt rules and
   the human at checkpoints. If the real workload drifts toward unsupervised hundreds-of-K
   runs, that's the signal to graduate to a fresh-process runner — a call to make on your own
   measured evidence, not on the off-domain numbers above.
