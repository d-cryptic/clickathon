# Worksheet — the publisher owns the user and hour/day tiers (ADR 0016)

> **Summary:** Codex audit §4.1 / queue item Q2: the ADR 0013 finalizer kept minute deltas current
> while `cc_user_minute` inflated (set union cannot retract) and `cc_hour_agg` went stale (never
> re-derived). Fixed by two new publisher phases — `hours` re-derives touched hours into the
> ReplacingMergeTree cube; `users` re-derives touched (minute, dims) buckets into `cc_user_minute`,
> which is now `ReplacingMergeTree(computed_at)` so a re-derivation REPLACES a bucket (retraction
> works) and `mv_user_minute` is retired. `publish-test.sh` now instantiates BOTH tiers in BOTH
> scratch DBs and compares them after growth, shrink, dimension change, straggler and idempotence.
> Branch `fix/incremental-publisher-tiers`, target `dev`. Nothing applied to `sonyliv`.

**Status** Complete · 2026-08-01

## Goal

Make the incremental publisher keep every advertised serving tier correct — or say, with numbers,
which tier cannot be kept correct at acceptable cost. Keep `make reconcile` green (17,028 / 0 /
2,917). ADR 0016.

## What was changed

| File | Change |
|---|---|
| `sql/45_user_concurrency.sql` | `cc_user_minute` → `ReplacingMergeTree(computed_at)`; `mv_user_minute` retired (a per-block MV writes PARTIAL states, which under replace semantics would erase complete buckets); one canonical re-derivation INSERT with retraction tombstones (empty `uniqExact` states for buckets whose coverage vanished); views read FINAL and hide zero buckets |
| `sql/50_hour_agg.sql` | PUBLISH_EXTRACT markers around the canonical INSERT; views filter all-zero retraction rows (an hour whose corrected deltas cancel yields a peak-0 row that supersedes the stale one) |
| `tools/publish.sh` | two new phases after `emitted`: `hours` (re-derive touched hours, scope on the ARRAY JOIN line — WHERE cannot precede ARRAY JOIN) and `users` (re-derive touched minute buckets, interval prefilter + exact minute scope); `extract_insert` cuts the canonical statements out of 45/50 so nothing is reimplemented |
| `tools/publish-test.sh` | both scratch DBs get 45+50; control rebuild rebuilds both tiers the way `build-model.sh` does; `compare()` gains 8 tier checks (user cells/total/peak, hour cube rows, day rows, hour peak); new PHASE 6 SHRINK (late pause pulls interval_end earlier) and PHASE 7 DIMENSION CHANGE (late burst flips dominant platform) |
| `tools/build-model.sh` | user tier is stage 2/6 — explicit backfill after intervals (the MV is gone); detects a pre-ADR-0016 engine and migrates by DROP + re-apply (derived state) |
| `docs/adr/0016-…` | the trade-off, the measurements, and what was rejected |

## Why the user tier was the hard one

`uniqExact` state merging is a set union; union has no inverse. The MV could ADD a user to a bucket
but never RETRACT one whose only covering interval shrank, changed dimension, or vanished. "Call the
MV again" cannot work — the representation had to change. Chosen: replaceable buckets
(`ReplacingMergeTree(computed_at)`) + full recompute of only the touched buckets by the publisher.
Rejected (numbers in ADR 0016): a signed retractable per-user representation (row count and read
cost), and a periodic full reset (bounded staleness — kept as the documented fallback).

## Correctness arguments worth keeping

- The touched-minute/hour scope is a provable SUPERSET from `cc_publish_batch` windows: old
  intervals ⊆ [lo, hi] (ADR 0013's claim-window completeness argument), new coverage ends ≤ hi +
  TAIL_S, close deltas land ≤ one minute later. Over-covering is idempotent — same input → same
  row at a newer version.
- Buckets are recomputed IN FULL (all sessions covering them, not only the batch's), because
  replacement discards the old state entirely.
- Retraction is explicit: buckets/hours that lose all coverage get an empty-state / all-zero row at
  a newer version; the serving views filter them, so "no concurrency" serves as no row — the same
  answer a fresh rebuild gives.

## How to verify

```bash
make reconcile          # TARGET=cloud — must stay 17,028 / 0 / 2,917 (untouched by this change)
make publish-test       # all "differing" rows 0 across all four tiers, all 8 stages
```

## Open questions / next steps

- Q8–Q10 (crash window before `claimed`, single-publisher lease, `marked_at` identity) are still
  open — ADR 0016 inherits ADR 0013's crash model and adds two idempotent phases to it, nothing
  more.
- Retraction tombstones accumulate keys until the next full rebuild (storage, not correctness).
- The `users` phase reads `cc_user_minute FINAL` for existing-bucket keys — at 100× the tier this
  becomes the phase's floor; the ADR records the measured cost and the mitigation (key-only read via
  a projection, or per-day scoping).
