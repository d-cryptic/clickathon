# ARCHITECTURE — the concurrency model

> **Summary:** Raw events → active intervals (heartbeat-gap derived) → minute deltas per dimension
> combination → concurrency as a running sum. Two parallel models: session-aware (accurate) and
> session-independent (always fresh); the gap between them is the excluded background time. Peak is
> computed at query time because it is not summable across dimensions. Open sessions are absorbed
> incrementally via a watermark, never by rebuild.

## Layers

**1 · `ev_raw`** — events exactly as delivered, `ORDER BY (video_session_id, event_timestamp)` so a
session's history is one contiguous range read. Partitioned by day.

**2 · `session_intervals`** — one row per contiguous *active* range. Derived by walking a session's
events in time order and closing an interval when the heartbeat gap exceeds `HEARTBEAT_GAP_S`.
`ReplacingMergeTree(interval_end)` so a late heartbeat **extends** the interval rather than
duplicating it. `is_open` marks sessions with no `VideoSessionEnd` yet.

**3 · `cc_minute_delta`** — the serving layer. `+1` at the minute an interval opens, `−1` at the minute
after it closes, keyed by `(platform, country, content_id, minute)`. Concurrency at minute *M* is the
running sum of deltas up to *M*.

**4 · `cc_minute_stateless`** — the session-independent baseline: `uniqState` of sessions seen active
in each minute, straight from heartbeats. Cheaper, always fresh, ignores gap logic. Comparing it with
the session-aware model is an explicit deliverable and produces the headline number.

## The three arithmetic rules

1. **Peak is not summable across dimensions.** platform+content and platform+country peak at different
   minutes. Never store a peak; take `max()` of the running sum at query time over the filtered set.
2. **Never sum a distinct count.** Rollups use `uniqState`/`uniqMerge`, never `SummingMergeTree` over
   `uniqExact` — that over-counted 9× in testing.
3. **Average is time-weighted** at grains coarser than the delta grain.

## Update handling

Open sessions keep growing. We hold a watermark: intervals whose session has no end and whose last
heartbeat is within the watermark are *provisional*. New heartbeats extend the interval
(`ReplacingMergeTree` on `interval_end`) and emit a compensating delta. Nothing is rebuilt.

## Trade-offs to defend

| Choice | Alternative | Why ours |
|---|---|---|
| Interval → delta | per-minute explosion | O(intervals) vs O(sessions × minutes) |
| Heartbeat gaps | bg/fg pairing | bg/fg are not guaranteed; 379 unmatched in the sample |
| Dimension-first sort key | time-first | dashboards filter then range-scan; measured 122× on a comparable A/B |
| Two parallel models | one | the comparison is the evidence that we exclude background time |
