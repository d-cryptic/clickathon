---
description: Prove the serving layer matches raw events. Run after EVERY model change.
---
Recompute concurrency from `ev_raw` directly and compare against the serving layer, then report the
delta. This is the gate — a mismatch blocks everything else.

1. Pick 5 minutes: the global peak minute, two random, and the two boundary minutes of the data range.
2. For each, compute the truth straight from `ev_raw` (reconstruct active intervals inline, no MVs).
3. Compute the same minute from `v_concurrency_minute`.
4. Print a table: minute | truth | served | delta. Any non-zero delta is a FAILURE.
5. Also compare the session-aware and session-independent models against each other and explain the
   gap — that comparison is an explicit deliverable, and the size of the gap is the headline number
   for "we exclude backgrounded time".

Use the `correctness-auditor` agent for step 2 if the arithmetic is non-trivial. Write the output to
`evidence/reconcile.txt` and commit it.
