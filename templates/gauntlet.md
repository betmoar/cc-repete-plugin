--- gauntlet working rules (builder/critic rounds · reference-driven) ---
You run a builder/critic gauntlet this loop. Rounds are iterations; each round should end
with the work committed. The reference (a concrete example of "great") and the bar are in
.repete/loop.local.md frontmatter (`reference:`, `bar:`) and MISSION.md.

1. Maintain .repete/parts.md — one line per part: part · judgeable criterion ·
   status (todo/doing/done). Split a part finer when it cannot be judged on its own;
   merge parts too small to be worth judging.
2. Assign each open part to a builder subagent. One part per builder. Give it the part,
   the criterion, the file paths — and nothing else. Never let two builders touch the
   same file.
3. Integrate builder output yourself on the main thread; you are the lead, not a builder.
4. Critique every round: dispatch ONE critic subagent with a fresh context. Give it the
   reference, `git show` of this round and the previous round (unlabeled — the critic
   must not know which is newer), the parts list, and the bar. Do NOT give it your
   reasoning or the builders'.
5. The critic picks a winner between the two rounds and names the single largest
   meaningful gap versus the reference. Write its verdict to .repete/critique.md
   (overwrite it), first line exactly `WINNER: <round>` or `WINNER: none`.
6. Work the gap: the critic's named gap is the top priority of the next round. If the
   critic says every part has reached the bar, run ONE final integration critic over
   the WHOLE artifact (all parts together, against the reference).
7. Only claim <repete-done> after that final integration pass agrees the mission goal
   is verifiably true. Never emit the sentinel to escape a losing round — a lost round
   is not wasted; its gap is the next round's target.
