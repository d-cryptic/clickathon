# Worksheet — continuously updated aggregates (ADR 0013)

> **Summary:** README step 4, "publish continuously updated aggregates", closed. A change-log MV on
> `ev_raw` marks which sessions each INSERT touched; `tools/publish.sh` re-derives only those and
> appends `-deltas(old) + deltas(new)`. The hot tier of ADR 0004/0005 is **declined** — a per-minute
> finalizer removes the lag it existed to cover. Proven in `evidence/publish.txt`: byte-identical to a
> from-scratch rebuild at every stage, 15 of 15 difference checks zero. **Nothing applied to
> `sonyliv`**; `make reconcile` green throughout (17,028 minutes, 0 mismatched, peak 2,917).
> Branch `feat/continuously-updated-aggregates`, target `dev`.

**Status** Complete · 2026-08-01

## Goal

Make "continuously updated" true rather than aspirational, prove it moves without a rebuild, keep the
gate green, and write ADR 0013.

## What was built

| File | Role |
|---|---|
| `sql/12_publish.sql` | `session_dirty` + `mv_session_dirty` (the change log), `cc_publish_batch`, `cc_publish_consumed`, `cc_publish_runs`, `v_cc_publish_lag` |
| `tools/publish.sh` | the finalizer — claim → negate → derive → prune → emit → commit, resumable by phase marker |
| `tools/publish-test.sh` | 9-phase proof against a from-scratch control rebuild; writes `evidence/publish.txt` |
| `docs/adr/0013-…md` | the decision, the trade-offs, and the two diffs it could not apply |
| `make publish DB=… [LOOP=60]`, `make publish-test` | entry points |

## The decision, in one line

Correction-by-diff applied to **every** touched session — not just to stragglers — makes the two-tier
lambda unnecessary: the watermark stops being a gate and becomes a freshness label.

## Key measurements

- straggler 46 min behind the watermark: corrected in **3.4 s**, reading **11.6%** of `ev_raw`,
  0 of 1,579 minutes differing from a rebuild
- 200 unchanged sessions republished: **0** minutes moved (`-deltas(X) + deltas(X) = 0`)
- adopting the layer on an already-built database: **0 sessions claimed**, nothing re-derived
- per-run cost breakdown: the lightweight `DELETE` (prune) dominates a small batch at ~1.4 s

## Two bugs this found in its own first draft

1. **A scalar cursor plus a safety lookback re-claimed the previous batch entire** — 6,659 sessions
   re-derived to absorb 5. Correct (re-publication cancels) but it turns incremental back into
   rebuild. Fixed by `cc_publish_consumed`, exact per-INSERT bookkeeping.
2. **The first A/B of read-scoping was measured mid-merge** and reported the event-time window as a
   *regression*. On a settled part set it is a 2.9× win. The harness now `OPTIMIZE`s first and
   averages three runs — an unsettled part set moves these numbers by 3× and inverts the ordering.

## Open questions / next steps

- **Going live on `sonyliv` is a human's call.** One `apply-sql.sh --database sonyliv sql/12_publish.sql`
  plus `PUBLISH_ALLOW_PROD=1 tools/publish.sh --database sonyliv --loop 60`.
- The per-run `DELETE` could be removed by making `session_intervals` a view over an append-only
  per-run ledger — touches tables other agents own, deliberately not done.
- `proj_by_session` re-measured at **12.8×** on the finalizer's real query shape (0.9% of `ev_raw`)
  for +91% storage; the shelved "1.00×" was measured on a shape that full-scanned. Not shipped.
- `sql/60_projection.sql` hard-codes `sonyliv.` and cannot be applied elsewhere — same defect
  ADR 0010 fixed in `sql/80_content.sql`.

## How to verify

```bash
make reconcile          # TARGET=cloud — must stay 17,028 / 0 / 2,917
make publish-test       # ~4.5 min, rebuilds two scratch DBs, all "differing" rows must be 0
```
