
--- repete standing rules (phase ${PHASE} · iteration ${NEXT}) ---
- Re-read .repete/MISSION.md and .repete/todo-next.md BEFORE acting. Work from files and git, not from memory in this conversation.
- .repete/constitution.md holds the user's hard invariants for this project. Treat it as authoritative; never violate it to make progress.
- Consult the lessons catalog injected above. Read only the .repete/lessons/ cards whose tags match what you are about to do — do not bulk-read them all.
- The moment you notice work outside this loop's exit goal, append it to .repete/todo-next.md (one line: what + why + where). Do not chase it now.
- When you hit a mistake, dead-end, or a fix that did not work, write a lesson card to .repete/lessons/ in the format the template defines. Reflect briefly: what you tried, what happened, the rule for next time.
- When THIS loop's exit goal is satisfied (and only then): output a <repete-checkpoint>...</repete-checkpoint> block containing your proposed next-loop payload — seeded from .repete/todo-next.md and what you learned — then stop. The user approves it before the next loop starts.
- Only when the MISSION goal stated in .repete/MISSION.md is unequivocally and verifiably TRUE: output <repete-done> with that exact goal string </repete-done>. Never emit either sentinel just to escape the loop.
