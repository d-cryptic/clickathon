# ARCHITECTURE — the concurrency model

> **Summary:** Raw events → active intervals (heartbeat-gap derived) → **hour-clipped** minute deltas per
> dimension combination → concurrency as a running sum within each hour. Serving is **two-tier**: an
> idempotent hot tier of heartbeat leases (immediate, `uniqExact`) stitched at a watermark to an
> append-only sealed tier (exact). That split *is* the session-independent vs session-aware comparison.
> Peak is never stored — it is not summable across dimensions — but hour-clipping makes it summable
> across time, so hour-grain maxes pre-aggregate. Nothing is ever updated or rebuilt.

## Layers

**1 · `ev_raw`** — events exactly as delivered, `ORDER BY (video_session_id, event_timestamp)` so a
session's history is one contiguous range read. Partitioned by day.

**2 · `session_intervals`** — one row per contiguous *active* range. Derived by walking a session's
events in time order and closing an interval when the heartbeat gap exceeds `HEARTBEAT_GAP_S`.
`ReplacingMergeTree(interval_end)` so a re-derivation replaces rather than duplicates. `is_open` marks
sessions with no `VideoSessionEnd` yet. Produced by the **finalizer**, not by a materialized view —
interval derivation is a cross-block, per-session, time-ordered computation and a streaming MV cannot
express it ([ADR 0004](adr/0004-two-tier-lambda-serving.md)).

**3 · `cc_minute_delta`** — the sealed serving layer. `+1` at the minute an interval opens, `−1` at the
minute after it closes, **clipped to each hour the interval touches**
([ADR 0003](adr/0003-hour-clipped-interval-splitting.md)). Keyed `(platform, country, content_id,
minute)`. Concurrency at minute *M* is `sum(delta) OVER (PARTITION BY toStartOfHour(minute) ORDER BY
minute)` — bounded to the hour, no carry-in from earlier history. **Append-only.**

**4 · `cc_hour_agg`** — per `(dims, hour)`, the hour's `max` of that running sum and its `integral`
(concurrency-seconds). Only correct because of hour-clipping. Peak over an hour-aligned range is the max
of stored maxes; average is `sum(integrals) / range_seconds`.

**5 · `cc_minute_hot`** — the hot tier and the session-independent model. Each heartbeat at `t` grants a
lease `[t, t + HEARTBEAT_GAP_S)`; an MV `arrayJoin`s it into the minutes that lease covers and
accumulates `uniqExactState(video_session_id)` ([ADR 0005](adr/0005-heartbeat-lease-semantics.md)).
Stateless, idempotent, TTL'd to a short window. **`uniqExact`, never `uniq`** — HLL's 1–2% error is a
silent correctness bug against an exact ground truth.

**6 · `v_concurrency`** — the stitch. `minute < W` reads the sealed running sum; `minute >= W` reads
`uniqExactMerge` over the hot tier.

## The three arithmetic rules

1. **Peak is not summable across dimensions.** platform+content and platform+country peak at different
   minutes; `max(a+b) ≤ max(a)+max(b)` and the gap is large. Never store a peak *per dimension*. Filter
   → sum deltas per minute → running sum → **then** `max()`. (Hour-clipping does make peak summable
   *across time*, which is what `cc_hour_agg` exploits — a different axis.)
2. **Never sum a distinct count.** `uniqExactState`/`uniqExactMerge`, never `SummingMergeTree` over a
   distinct count — that over-counted 9× in testing. Session-level concurrency *is* summable across
   dimension buckets (a session has one platform, one content); user-level is not.
3. **Average is time-weighted.** The integral of the curve over range length, zero-minutes included.
   Cross-check it against `sum(interval durations clipped to range) / range_seconds`, which touches no
   delta layer at all.

## Update handling

Three arrival classes, each absorbed without a rebuild:

| Arrival | Absorbed by | Mechanism |
|---|---|---|
| Newer than watermark `W` | hot tier | `uniqExact` is idempotent and monotone — replays are no-ops, late beats are pure additions |
| In normal order | finalizer | re-derives **only sessions touched since the last run**, appends sealed deltas |
| Older than `W` (straggler) | correction-by-diff | recompute that one session with and without the straggler, append the difference ([ADR 0006](adr/0006-late-arrival-correction-by-diff.md)) |

Open sessions need no special path: they keep renewing leases in the hot tier and stay provisional in
the sealed tier until `W` passes them. **`W` is the metric to instrument in ClickStack** — watermark lag
is the observable expression of the whole design.

## Trade-offs to defend

| Choice | Alternative | Why ours |
|---|---|---|
| Interval → delta | per-minute explosion | O(intervals) vs O(sessions × minutes) |
| Hour-clipped deltas | unclipped | removes the carry-in scan-from-`t=0`; makes hour-grain peak pre-aggregable (day peak reads 24 rows/combo, not 1,440) |
| Heartbeat gaps | bg/fg pairing | bg/fg are not guaranteed; 379 unmatched in the sample — **conditional on the gating measurement below** |
| Lease hot tier | compensating deltas | compensation needs the interval's previous end, which a stateless MV cannot know without a racy read-modify-write |
| Two tiers | one | the comparison is the evidence that we exclude background time — and here it is structural, not bolted on |
| Correction by diff | `ALTER … UPDATE` / partition rebuild | exactly as correct as a rebuild, of one session; cost scales with stragglers, not history |
| Dimension-first sort key | time-first | dashboards filter then range-scan; measured 122× on a comparable A/B |

## The premise this all rests on

**Unverified:** that heartbeats *stop* while the app is backgrounded. If they continue, gap detection is
blind, and both ADR 0001 and the lease model need a state-machine layer over background/foreground and
pause events. Measure it before writing model SQL — see [TODOS.md](../TODOS.md) `[H1]` gates and
[docs/artifacts/](artifacts/) for the query.

Full reasoning, with diagrams for every step above:
[docs/artifacts/2026-08-01-concurrency-model-deep-dive.html](artifacts/2026-08-01-concurrency-model-deep-dive.html).
