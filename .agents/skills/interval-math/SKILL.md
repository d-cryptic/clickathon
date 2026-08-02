---
name: interval-math
description: Correct active-interval reconstruction and concurrency arithmetic for the SonyLIV problem. Use when writing or reviewing any interval, delta or peak/average query.
---

# Interval and concurrency arithmetic

## Deriving active intervals
Signals, in order of reliability:
1. **Heartbeat cadence.** Emitted every 60s. A gap > `HEARTBEAT_GAP_S` (default 150s ≈ 2.5 missed
   beats) closes the active interval.
2. **`VideoSessionStart` / `VideoSessionEnd`** bound the session — but an end may be **absent**
   (open session). Never assume it exists.
3. **`AppBackgrounded` / `AppForegrounded`** corroborate only. They are explicitly **not guaranteed**;
   measured 379 unmatched and 418 sessions that background and never return.

Give the final heartbeat of an interval **one cadence** of credit (`TAIL_GRACE_S`), not the whole gap.

## Deltas, not explosion
Per-minute explosion is O(sessions × minutes) and collapses at scale. Emit `+1` at the minute an
interval opens and `−1` at the minute after it closes; concurrency is the running sum.

```sql
-- concurrency at each minute
SELECT minute, sum(sum(delta)) OVER (ORDER BY minute) AS cc
FROM cc_minute_delta GROUP BY minute ORDER BY minute
```

## The two arithmetic traps
1. **Peak is not summable and not decomposable.** platform+content may peak at a different minute
   than platform+country. Never store one peak; take `max()` of the running sum at query time, over
   the filtered combination.
2. **Never sum a distinct count across buckets.** A `SummingMergeTree` over `uniqExact` over-counts —
   measured **9×** (45,000 vs a truth of 5,000) on a comparable cascade. Use
   `AggregatingMergeTree` + `uniqState`/`uniqMerge`, and `-MergeState` for a second hop.

## Average concurrency
Time-weighted, not a mean of per-minute values, unless every bucket is the same width. At minute grain
they are equal; at hour/day grain over a partial range they are not. State which you used.
