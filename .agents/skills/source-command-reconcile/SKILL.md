---
name: "source-command-reconcile"
description: "Prove the serving layer matches raw events. Run after EVERY model change."
---

# source-command-reconcile

Use this skill when the user asks to run the migrated source command `reconcile`.

## Command Template

Run `tools/reconcile.sh`. It reconstructs state-gated intervals from `ev_raw` in temporary tables and
compares five representative minutes against the signed-delta serving layer. This is the gate — a
mismatch blocks everything else.

1. Pick five minutes: the global peak and four evenly spaced samples across the raw event-time range.
2. For each, compute truth straight from `ev_raw` (reconstruct active intervals inline, no MVs).
3. Reconstruct the same global minute from hour-local `cc_minute_delta` boundaries plus the latest
   published per-session correction state.
4. Print `minute | truth | served | delta | result`. Any non-zero delta is a FAILURE.
5. Use the state-gate measurements in [ADR 0007](../../docs/adr/0007-state-gate-heartbeats.md) when
   explaining the difference from a gap-only model; re-run that measurement whenever event semantics
   change.

Use the `correctness-auditor` agent for step 2 if the arithmetic is non-trivial. Write the output to
`evidence/reconcile.txt` and commit it.
