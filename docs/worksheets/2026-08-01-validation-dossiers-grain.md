# Worksheet — 2026-08-01 · definition dossiers 05/06 + scoping the dedup proof

> **Summary:** Wrote the two definition dossiers the Codex audit demanded (queue Q3, Q5):
> doubts/05 (minute-boundary membership — 505 intervals on the boundary, half-open moves the graded
> peak 2,917→2,916, gate structurally blind) and doubts/06 (dedup NOT inert at 7-dimension grain —
> boundaries byte-identical but 6 audio_language attributions flip, unk peak 183→184). Scoped —
> did not replace — evidence/dedup.txt's verdict to the grain it holds at. Every audit number
> re-measured against Cloud `sonyliv` before being written down; two did not reproduce exactly and
> the dossiers carry what was measured, plus the grain subtlety the discrepancy exposed.

## Goal

Queue items Q3 and Q5 from docs/WORKTREE_QUEUE.md: mentor dossiers in the doubts/ format for (A)
minute-boundary semantics and (B) dedup at filter grain, plus scoping the existing dedup proof.
Definition questions — the model SQL is deliberately untouched. No writes to `sonyliv`; every query
was a read-only SELECT (tools/ch -c).

## Decisions (why, not just what)

1. **Merged `dev` into this branch before measuring anything.** The branch base predated the current
   model (old: 30,769 intervals / peak 2,887; dev: 30,323 / 2,917), and the briefs' source docs
   (codex-validation/, WORKTREE_QUEUE.md) existed only on dev. Merge was clean.
2. **Re-measured every audit claim rather than transcribing it.** Reproduced exactly: 505 boundary
   intervals / 493 sessions; peak 2,917→2,916; 6 attribution flips; hin/non/unk curves moving on
   18/15/26 minutes; audio peak 183→184 — for the raw string `unk`, not `UNK` as §4.7 wrote it.
3. **The audit's "91 minutes / 302 viewer-minutes" did not reproduce exactly — and the reason is a
   finding.** The half-open trim applied per interval (truth grain) gives 92/305; applied per merged
   run (what a naive serving edit would do) gives 90/271, because 40_deltas' merge fold truncates
   seconds before the boundary test. Two "half-open" implementations disagree with each other, so
   doubts/05 §4 pins where the trim must happen (before the merge, raw end carried through the fold).
4. **Dedup arm pinned deterministically** (`ORDER BY full-key … LIMIT 1 BY 4-col key`) so the A/B
   isolates dedup, mirroring the old proof's min()-for-any() discipline. The worked example
   (session 3575B56C…, votes unk 11/hin 5 → 5/5 tie → tie-break picks hin) shows both the count
   sensitivity AND the tie-break path.
5. **evidence/dedup.txt scoped, not rewritten.** The old verdict was right at total grain and its
   own guard (a) predicted precisely this break — that arc (proof → guard → guard fires) is more
   credible than a silent replacement. Scope note after VERDICT, full re-measure as new section 6.
6. **No ADR written.** ADR 0016 stays reserved (WORKTREE_QUEUE assigns it) for recording the dedup
   policy once the mentor answers; writing it now would encode a guess as a decision.

## State: DONE

- doubts/05-minute-boundary-membership.md — evidence, exact wording, 4-row decision table
  (includes the instant-sampling reading: peak would be 2,507, −14.1%).
- doubts/06-dedup-at-filter-grain.md — same format; gate-blindness stated (90_reconcile compares
  totals only, no dimension columns).
- evidence/dedup.txt — scope note + section 6; original sections untouched.
- doubts/README.md — index rows 05/06 + two "how it changed the question" bullets.

## How to verify

All queries are inline in the two dossiers; each runs read-only via `tools/ch -c "<sql>"` against
Cloud. Cross-checks: interval totals must match dev truth (30,323 / 1,978.1 h / peak 2,917 @ 10:56);
the A/B boundary hash must be identical across arms (1595692701993512111).

## Open questions / next step

- Mentor answers for 05 and 06 → record inline, then ADR 0016 (dedup policy) and, if half-open,
  the two-file trim-before-merge change described in 05's decision table.
- Operator feedback (in lieu of AGENT_FEEDBACK.md, which this brief does not own): the audit's
  §4.2 91/302 figure is uncited as to grain — audit numbers that depend on where a convention is
  applied should state the grain, or two agents "verifying" each other will keep disagreeing by ±3.
