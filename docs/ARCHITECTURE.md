# ARCHITECTURE — the concurrency model

> **Summary:** Raw events → state-gated active intervals → **hour-clipped** minute deltas per dimension
> combination → concurrency as a running sum within each hour. The implemented historical spine is
> deterministic and excludes backgrounded and paused heartbeats; a published correction-state finalizer
> incrementally absorbs late or evolving sessions, while a published bounded exact tail serves the newest
> event-time window. Peak is never summable across dimensions; hour clipping removes carry-in, while
> only additive integrals or exact filter cuboids may be rolled up. Read
> [ADR 0007](adr/0007-state-gate-heartbeats.md) first.

## Layers

**1 · `ev_raw`** — events exactly as delivered, `ORDER BY (toStartOfHour(event_timestamp), platform,
video_session_id, event_timestamp)`, partitioned by day
([ADR 0002](adr/0002-order-by-time-bucket-then-platform.md) — measured **17.3× better** on the
dashboard shape than leading with the session id).

> ⚠ **This design makes single-session lookup hot, and the key no longer serves it.** The finalizer
> re-derives only *touched* sessions and straggler correction reads exactly one — both are point
> lookups by `video_session_id`, which is now third in the key rather than first. ADR 0002 anticipated
> precisely this and names the remedy: *"add a `PROJECTION` ordered by `video_session_id` rather than
> reverting the key."* Add it at H4 and measure it — do **not** revert ADR 0002, whose 17.3× is on the
> access pattern that runs far more often.

**2 · `session_intervals`** — one row per contiguous *active* range. An event-time state machine gates
heartbeats on foreground AND unpaused playback, then closes a run on a >150-second gap or immediate
stop marker. `is_open` marks sessions with no end. It is produced by the materializer, not an MV:
interval derivation is cross-block, per-session and time ordered ([ADR 0007](adr/0007-state-gate-heartbeats.md)).

**3 · `cc_minute_delta`** — the compact bootstrap serving layer. `+1` at the minute an interval opens, `−1` at the
minute after it closes, **clipped to each hour the interval touches**
([ADR 0003](adr/0003-hour-clipped-interval-splitting.md)). Keyed `(platform, country, content_id,
minute)`. Concurrency at minute *M* is `sum(delta) OVER (PARTITION BY toStartOfHour(minute) ORDER BY
minute)` — bounded to the hour, no carry-in from earlier history. **Append-only.**

**4 · Future rollups** — an hourly integral per base dimension combination is additive and may be
benchmarked. An hourly peak is valid only when materialised for the exact requested filter cuboid; it is
not safe to sum across platform/content/country groups. The reconciled minute ledger remains peak authority
until an evidence-backed cuboid is selected ([ADR 0015](adr/0015-filtered-peak-is-not-additive.md)).

**4 · `session_delta_base` + `session_delta_correction_stage`** — the update layer. The bootstrap stores
each session's contribution; a finalizer re-derives only sessions whose `ingested_at` is in an overlapping
source window, stages their complete target correction, and publishes it atomically at the query boundary.
The serving query overlays `argMax(correction_delta, run_sequence)` from published runs on the compact
baseline. See [ADR 0006](adr/0006-late-arrival-correction-by-diff.md).

**5 · `exact_tail_minute_stage`** — the old ungated lease MV is invalid because heartbeats survive known
inactive states. `refresh-tail.sh` snapshots only a short, state-machine-derived event-time window after
a finalizer run. A snapshot is query-selected only when its `finalizer_run_sequence` equals the selected
correction sequence; a newer correction makes an older tail invisible rather than stale. It replaces the
ledger only inside its recorded `[event_watermark, tail_until]` range, never after it. See [ADR 0012](adr/0012-exact-tail-publication-fence.md).

## The three arithmetic rules

1. **Peak is not summable across dimensions.** platform+content and platform+country peak at different
   minutes; `max(a+b) ≤ max(a)+max(b)` and the gap is large. Never store a peak *per dimension*. Filter
   → sum deltas per minute → running sum → **then** `max()`. An exact peak for one fully aggregated hour
   can be maximized across full hours, but only after the query's dimensions are already combined; this is
   why a generic per-dimension `cc_hour_agg` is unsafe.
2. **Never sum a distinct count.** `uniqExactState`/`uniqExactMerge`, never `SummingMergeTree` over a
   distinct count — that over-counted 9× in testing. Session-level concurrency *is* summable across
   dimension buckets (a session has one platform, one content); user-level is not.
3. **Average is time-weighted.** The integral of the curve over range length, zero-minutes included.
   Cross-check it against `sum(interval durations clipped to range) / range_seconds`, which touches no
   delta layer at all.

## Update handling

The finalizer handles normal arrival and stragglers as a versioned correction overlay. The exact tail
then gives a bounded, current snapshot without allowing stale data to override that correction:

| Arrival | Absorbed by | Mechanism |
|---|---|---|
| Newer than watermark `W` | exact tail | versioned bounded minute snapshot calculated from state-machine markers |
| In normal order | finalizer | re-derives touched sessions and publishes their replacement correction state |
| Older than `W` (straggler) | correction overlay | same re-derivation; a published correction replaces the previous one |

Open sessions remain provisional in the bounded tail until `W` passes them. **`W` is the metric to
instrument in ClickStack** — watermark lag is the observable expression of the whole design.

## Trade-offs to defend

| Choice | Alternative | Why ours |
|---|---|---|
| Interval → delta | per-minute explosion | O(intervals) vs O(sessions × minutes) |
| Hour-clipped deltas | unclipped | removes the carry-in scan-from-`t=0`; permits additive hour integrals and an exact-hour peak only at a fully specified query cuboid |
| State-gated heartbeats | gap-only / bg-fg pairing | state markers prevent known false positives; heartbeat cadence still bridges missing markers |
| Bounded exact tail | stateless heartbeat leases | a stateless MV cannot see previous app/playback state and would count known-inactive heartbeats |
| Sealed delta + exact tail | one mutable history table | bounded mutability keeps historical reads append-friendly |
| Correction by diff | `ALTER … UPDATE` / partition rebuild | exactly as correct as a rebuild, of one session; cost scales with stragglers, not history |
| Dimension-first key **on the serving tables** | time-first | dashboards filter then range-scan; measured 122× on a comparable A/B |
| Time-bucket-first key **on `ev_raw`** | session-id-first | measured 17.3× better on the dashboard shape, identical on the full interval rebuild ([ADR 0002](adr/0002-order-by-time-bucket-then-platform.md)) |
| `PROJECTION` by `video_session_id` | reverting ADR 0002 | our finalizer and correction paths are point lookups by session; a projection restores them without losing the 17.3× |

## The premise this all rests on

**Verified:** heartbeats continue while the app is backgrounded and paused. The gates found 4,503 and
94,463 such rows respectively, so all authoritative interval work uses the state machine in ADR 0007.

Full reasoning, with diagrams for every step above:
[docs/artifacts/2026-08-01-concurrency-model-deep-dive.html](artifacts/2026-08-01-concurrency-model-deep-dive.html).
