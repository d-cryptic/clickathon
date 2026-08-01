# RESEARCH — foreground-only concurrency model

> **Summary:** Research and the supplied data converge on an event-time, state-gated sessionizer:
> watermarking bounds lateness, app/playback state prevents false heartbeat activity, and hour-clipped
> signed deltas make deterministic range reads cheap. The implemented spine is `ev_raw →
> session_intervals → cc_minute_delta`, with a published per-session correction overlay for late data
> and a publication-fenced, bounded exact tail rather than an ungated heartbeat lease MV.

## What the source material changes

| Finding | Source | Decision here |
|---|---|---|
| Event time, not processing time, preserves reproducibility; a watermark is an explicit completeness policy. | [Flink event-time guide](https://nightlies.apache.org/flink/flink-docs-stable/docs/learn-flink/streaming_analytics/) | Record ingestion time and seal only behind a measured watermark. |
| Late events can merge formerly separate session windows. | [Flink window semantics](https://nightlies.apache.org/flink/flink-docs-release-1.19/docs/dev/datastream/operators/windows/) | Corrections must diff old and new session output; re-deriving a row alone cannot delete a formerly valid interval. |
| Incremental ClickHouse MVs process only the inserted block. | [ClickHouse MV guidance](https://clickhouse.com/blog/common-getting-started-issues-with-clickhouse) | Do not put cross-block state reconstruction in an MV. Use an explicit finalizer. |
| Pre-aggregated MVs and projections trade write work for fast repeated reads. | [ClickHouse best practices](https://clickhouse.com/blog/10-best-practice-tips) | Store compact signed boundaries and add the session projection; do not materialize all historical minutes. |
| Real stream engines model session windows as mergeable, keyed event-time windows. | [Apache Flink](https://github.com/apache/flink) and [RisingWave](https://github.com/risingwavelabs/risingwave) | Treat a late heartbeat as a potential bridge, not merely an extension. |

## Metric contract: sessions, not distinct people

The supplied statement defines concurrency as sessions that overlap a minute and its worked example
calls the peak “concurrent sessions.” The scored serving metric is therefore active playback-session
concurrency. `user_id` remains valuable for a separate audience metric, but a user can hold multiple
sessions, so `uniqExact(user_id)` must never replace or be summed into the signed session-delta serving
path. This resolves the product wording “viewers” without silently changing the ground-truth contract.

## Source acceptance is part of correctness

The raw table is evidence, not permission to aggregate. The new preflight rejects input that cannot be
interpreted deterministically by the current state machine and reports retry/terminal anomalies that can.
This draws the same boundary as ordered-stream systems: an immutable event identity plus a source-partition
offset gives a replayable cursor, while a timestamp alone does not. Kafka guarantees order only within a
partition and exposes its offset as the compact replay position; a production playback source should carry
the equivalent `(source_partition, source_offset, event_id)` contract. [Kafka's design documentation](https://kafka.apache.org/41/design/design/)
explains both the per-partition ordering boundary and why a checkpoint is one position per partition.

## Measurements on the supplied data

| Question | Result | Design impact |
|---|---:|---|
| Do heartbeats continue while backgrounded? | 4,503 | Gap-only logic is incorrect. |
| Do heartbeats continue while paused? | 94,463 | Pause is a hard gate, not a cosmetic event. |
| Pause-to-resume gaps at least one minute | 6,868 | This is material at minute grain. |
| Unpaired background markers | 453 | Do not depend on pairing to resume. |
| Delta vs interval count on five busiest sampled minutes | 0 difference | Hour clipping and boundary emission reconcile. |
| Exact duplicate raw rows | 4,209 | Dedupe retry copies in the derived model, never by mutating raw. |
| Sessions with platform / content drift | 95 / 1 | Split intervals on serving-dimension changes. |
| Heartbeats after `VideoError` | 743 | Error is diagnostic data, not a terminal playback transition. |

## Main-environment shadow comparison

The user-owned main ClickHouse instance (`ch`) has the full raw corpus loaded (905,558 events) but no
derived rows. To compare semantics without mutating that environment, both builders were executed as
client-session `Memory` tables over its raw events. The current state-gated builder produced 30,931
intervals and 6,344,758 active seconds. The earlier gap-driven/pause-clipping builder produced 30,769
intervals and 7,017,592 active seconds: **672,834 extra seconds, 10.6% above the state-gated result**.

This is not a private-ground-truth claim. It is a controlled semantic-difference measurement: the
legacy path treats the sparse heartbeat stream as sufficient evidence through background state, while
the revised path rejects heartbeats after a known background. It is strong evidence that background
state is a first-class correctness boundary, and it validates that our isolated test container and the
main raw source are bit-for-bit compatible for the revised derivation. No table in the main environment
was changed during this comparison.

## Implemented model

```
raw event stream
  │  app state + playback state + heartbeat cadence
  ▼
state-gated active intervals       O(number of eligible runs)
  │  split on gap or hard stop
  ▼
hour-clipped signed deltas         O(intervals × crossed hours)
  │  +1 at local hour start, -1 after the final active minute
  ▼
filtered change-point serving      running sum only inside requested hour
```

The sessionizer fails closed after an unmatched background or pause and resumes only on a subsequent
eligible heartbeat. It gives the final heartbeat 60 seconds of credit, caps that credit at a stop
marker, splits on serving-dimension drift, and uses a 150-second continuity gap.
`queries/materialize_intervals.sql` is the executable specification.

## Ideas evaluated

| Idea | Verdict | Why |
|---|---|---|
| Per-minute history for every session | Reject | Correct but O(session-minutes) storage. |
| Gap-only intervals | Reject | Proven to count backgrounded and paused heartbeats. |
| Stateless `uniqExact` heartbeat leases as truth | Reject | Cannot retract or observe prior state across MV blocks. |
| Hour-clipped delta ledger | Adopted | Exact, append-friendly arithmetic with bounded carry-in. |
| Session-id projection on raw | Adopted | Preserves dashboard-oriented base key while serving finalizer point reads. |
| Published per-session correction state | Adopted | Replace a touched session's target marker correction only after its run is published. |
| Bounded exact mutable tail | Adopted | Publish a complete small minute snapshot only after its finalizer run; stitch it only while that correction version remains current. |
| Hour max + integral rollup | Next | Safe only after the delta ledger is reconciled; accelerates hour/day peak and time-weighted average. |
| Approximate distinct sketches | Reject for serving | Private ground truth makes even small error unacceptable. |

## Implemented finalizer protocol

`session_delta_base` persists each session's bootstrap contribution and `session_delta_correction_stage`
persists its complete replacement correction. A run moves through `prepared → staged → published` in an
immutable log; only published rows affect serving queries, where `argMax` chooses the latest target state.
This is deliberately not an additive retry path: source-time overlap reprocesses boundary arrivals safely,
and a crash before publication remains invisible. `refresh-tail.sh` then materializes a complete bounded
minute snapshot from those same markers. Its run log records the finalizer sequence it used; the serving
query selects it only when that sequence is still current. A new correction therefore falls back to the
delta-plus-correction path until a replacement tail is published.

## Architecture options, from a data-engineering perspective

| Architecture | Correct late bridge? | Fresh open session? | Operational cost | Decision |
|---|---|---|---|---|
| Rebuild all history on every refresh | yes | eventually | grows with all history | reject except recovery |
| Stateless heartbeat lease MV | no | yes | low | reject: cannot observe state across insert blocks |
| Refreshable MV over a recent time range | yes inside range | bounded by refresh | repeatedly scans the range | recovery/backstop only |
| Watermark + per-session snapshots + signed deltas | yes | yes, with exact tail | proportional to touched sessions | **recommended** |
| External Flink/Beam sessionizer + ClickHouse serving | yes | yes | highest platform surface area | 100x scale option, not hackathon MVP |

The recommended design is a practical application of the Dataflow distinction between event time and
processing time: the raw event retains both `event_timestamp` and `ingested_at`; a watermark says
which event-time range is provisionally complete; and a correction is a first-class signed change, not
a destructive rewrite. [The Dataflow Model](https://research.google/pubs/the-dataflow-model-a-practical-approach-to-balancing-correctness-latency-and-cost-in-massive-scale-unbounded-out-of-order-data-processing/)
frames this explicitly as a correctness/latency/cost choice. [Aion](https://arxiv.org/abs/2003.03604)
shows why retaining indefinitely reopenable state in memory is unsafe; the bounded tail keeps only the
state that can still change.

### Recommended serving topology

```
append-only ev_raw(event time, ingestion time, payload fingerprint)
        │
        ├── ingest-time index: find sessions touched since checkpoint
        ├── session-id projection: fetch the complete event-time history for one session
        ▼
event-time state machine → interval snapshot(version, session, interval)
        │ compare previous and next sealed interval set
        ▼
signed hour-clipped delta ledger                 versioned exact tail
        │ minute < W                              │ minute >= W
        └────────────────────── stitch ───────────┘
                             ▼
                         dashboard query
```

The finalizer should checkpoint the **maximum ingestion time observed**, not merely maximum event time.
That is the only reliable way to discover a straggler after an event-time range has been sealed. Each
checkpoint needs a run id, source ingestion high-watermark, calculated event-time watermark, status,
row counts, and checksum. A failed run must never advance the checkpoint; a replay must create either
the identical signed batch under an insert-deduplication token or no new batch at all.

### Watermark policy is an operational contract, not a magic constant

The supplied CSV was bulk-loaded, so its `ingested_at` values cannot measure real arrival disorder and
must **not** be used to choose `W`. In production, record `arrival_lag = ingested_at - event_timestamp`
per source/partition and choose `W` from a documented tail percentile plus a correction budget. Also
record the maximum observed event time and source id at every run; an idle source must not freeze
global progress forever, but declaring it idle is itself an auditable decision. Flink makes the same
two operational points: the global watermark follows the slowest input, while an idle input needs an
explicit timeout; allowed-late session events can produce updated, merged results.

Recommended initial policy once real arrivals exist:

1. Seal only through `min(source_watermarks) - safety_margin`, never through wall clock alone.
2. Keep a bounded exact tail for `W`; send events older than `W` through deterministic session-diff
   correction and count them.
3. Page on watermark lag and correction age, not merely raw ingest lag. A fresh input with a stuck
   watermark is stale serving data.
4. Recalculate `W` only from an observed arrival-lag distribution, separately by source. Do not tune it
   from this static file's event-time gaps.

This is the practical inference from [Flink’s watermark debugging guide](https://nightlies.apache.org/flink/flink-docs-stable/docs/ops/debugging/debugging_event_time/),
its [idleness semantics](https://nightlies.apache.org/flink/flink-docs-stable/docs/dev/datastream/event-time/built_in/),
and its warning that late session events can merge formerly emitted windows. It directly motivates the
pending H1 arrival-order measurement and the `finalizer_run_log` ledger.

## Edge-case register

| Edge case | Evidence / failure mode | Required handling |
|---|---|---|
| Exact duplicate event payloads | 4,209 rows; no source event id | Preserve raw; collapse exact payload copies only in derivation; ask for immutable event id. |
| Dimension drift mid-session | 95 platform, 1 content, 120 user drift sessions | Split interval on serving dimensions; never use `any()` for a dashboard bucket. |
| Error followed by playback | 743 heartbeats after `VideoError` | Record as QoE signal; do not terminate playback without an explicit stop. |
| Tied timestamps | 159,434 timestamps have ≥2 events after exact-payload dedupe; one has simultaneous pause + resume | Define deterministic transition precedence: stop → start → heartbeat. |
| Exact minute stop | a half-open interval can end at `HH:MM:00.000` | emit the negative delta at that minute, not one minute later. |
| Missing or unmatched state | 453 unpaired backgrounds; 6,418 unpaired pauses | Fail closed; fresh eligible heartbeat is the only restart proof. |
| State event scope | `AppBackgrounded` names an app process but the source carries only a session id | Treat delivered events as session-scoped; require player instance and scope for any producer that fans one state change across sessions. |
| Open sessions | 144 state-machine-open sessions at a 10:30 cut; 75 overlap that cutoff minute | `truncation-test.sh` proves no truncated interval extends more than its 60-second tail grace. |
| Long-lived session id | one supplied id spans 157,101 seconds (43.6h) | do not expire FSM state by session age; expire only after inactivity plus watermark. |
| Late bridge event | one late heartbeat can merge two old intervals | Snapshot the old interval set and append set-difference deltas. |
| Event-time clock faults | device clock can regress, jump, or be in future | Quarantine impossible timestamps; cap allowed future skew; expose counts. |
| Ingestion retry after dedup window | block-level dedup is bounded | use explicit batch ids and a payload fingerprint audit, not only MergeTree dedup. |
| Content dimension correction | `video_type` can change after an MV join | resolve content at query time with `dictGet`, or version the dimension assignment. |
| User-level metric confusion | one user can own multiple sessions | session concurrency is additive by bucket; user concurrency needs distinct state, never summed. |
| Hot-key skew | Android phone is 69.5% of events; top content is 9% | shard/partition and load-test the hot key, not a uniform sample. |
| Tiny insert parts / MV fan-out | each MV and projection amplifies writes | batch inserts; measure parts, merge backlog, and source-to-target lag. |

After exact-payload dedupe, the supplied stream has no same-timestamp conflicts in `platform`,
`country`, or `content_id`; it has one simultaneous stop/start conflict, which the explicit stop-before-
start precedence resolves. This is evidence for the supplied file only. `tools/audit-data.sh` now treats
a non-zero tied-dimension conflict on the unseen file as a source-contract escalation: require a
producer sequence or quarantine the ambiguous state transition rather than relying on physical row order.
`tools/synthetic-edge-test.sh` complements this observed-data audit with adversarial cases that the source
does not necessarily contain: backgrounded/paused heartbeat suppression, dimension handoff caps, exact
payload retry collapse, `VideoError` continuation, and a stop exactly on a minute boundary.

### Dimensions have temporal semantics too

The benchmark treats `content_dim` as static, but the physical table is a `ReplacingMergeTree` without a
source version. That engine is a storage compaction tool, not a definition of which conflicting row wins.
The acceptance gate therefore rejects a content id whose `(title, video_type, category)` values disagree;
an exact retransmit is permitted. This preserves deterministic current-catalogue filtering today.

For production, choose and expose one of two distinct metrics: **watch-time attribution** joins an interval
to the content-dimension version valid when it was watched; **current-catalogue attribution** joins it to the
latest catalogue value. They can legitimately produce different historic curves after a content recategorises.
Do not make this a side effect of asynchronous ReplacingMergeTree merges or `FINAL`; carry a dimension version
or effective-time range, and test the chosen semantics on a replay.

### Semantic payloads need a compatibility policy

`VideoHeartbeat` contains 41 observed payload values, so its name must not be mistaken for a strict event
schema. The crucial distinction is **state transition** versus **liveness annotation**. The current model
changes playback state only for `pause` / `resume`, the clearly specified actions; it continues to use all
other heartbeat payloads as proof that the foreground, unpaused session is still alive. This is deliberate:
the 380 `speed-pause` / `speed-resume` pairs occur at the same event timestamp, `AdPause` commonly has a
follow-up heartbeat within seconds, and `download_asset_play_stop` is followed by same-timestamp telemetry.
Calling any of these an unconditional playback stop would introduce a second, undocumented metric.

The future-data policy is therefore conservative: unknown *event types* fail the source-contract gate,
while unknown heartbeat payloads land as opaque liveness signals and are counted. A payload becomes a state
transition only after the producer declares its semantics, its ordering with pause/background is specified,
and a sensitivity run demonstrates the intended effect. The same gate now quarantines a timestamp more than
five minutes ahead of durable ingestion; this catches impossible device clocks without confusing ordinary
late arrivals with bad chronology.

### State scope is a separate identity problem

An event called `AppBackgrounded` might conceptually apply to a process, device, account, or one player
instance. The benchmark stream supplies it beside `video_session_id`, not beside a device/player key. The
observed corpus supports session-local handling: no app-state timestamp is shared by two overlapping sessions
of the same user, although 61 users have overlapping session lifetimes and 120 sessions contain more than one
user id. It does **not** prove that `user_id` is a state key—indeed it disproves that shortcut.

The current FSM therefore scopes a state transition to the `video_session_id` delivered with it. A live SDK
that emits one app-state event for several players must add `player_instance_id` plus `state_scope`; fan that
transition out upstream or key the external state processor by its declared scope. Guessing from user id would
either suppress unrelated sessions or leak background playback into the metric.

Finalizer phase visibility has a similar ordering requirement: client wall clocks can tie at millisecond
precision, so `prepared < staged < published < aborted` is an ordered enum and consumers select the maximum
phase, never an arbitrary timestamp-tied `argMax` winner.

## What the experiments say about tunables

The state-gated stream has 733,748 comparable eligible-heartbeat gaps. All gaps have p50/p90/p95/p99
of 0/40/40/70 seconds because same-timestamp event bursts are common; nonzero gaps have
p50/p90/p95/p99/p99.9 of 20/40/40/204/1,274 seconds. 3,947 gaps exceed 150 seconds. The provided
metadata calls the cadence one minute, but the observed dominant cadence is 40 seconds with bursty
same-timestamp rows. A 60-second tail therefore gives roughly one observed cadence plus jitter, while
150 seconds permits missed signals.

| gap seconds | tail seconds | intervals | active seconds |
|---:|---:|---:|---:|
| 120 | 0 | 24,441 | 6,021,784 |
| 120 | 60 | 30,965 | 6,342,261 |
| 120 | 150 | 30,965 | 6,364,013 |
| 150 | 0 | 24,416 | 6,026,321 |
| 150 | 60 | 30,931 | 6,344,758 |
| 150 | 150 | 30,931 | 6,363,625 |
| 180 | 0 | 24,409 | 6,028,574 |
| 180 | 60 | 30,917 | 6,346,171 |
| 180 | 150 | 30,917 | 6,363,778 |

The 120/150/180-second gap choice changes total credited time by less than 0.5% on this file, whereas
tail choice changes it by about 5.4%. The current 150/60 default is a conservative, measured choice,
not a ground-truth claim. The submission should show this sweep and expose the values as parameters.

## Physical-design and operations conclusions

- The hour split costs only 8.3% more boundary rows: 2,442 of 30,931 intervals cross an hour; 33,507
  deltas serve 30,931 intervals. This is a very favourable exchange for independent hour reads.
- The base raw sort key should remain dashboard-oriented; the measured session projection is selected
  for point reads. On the local 905,558-row corpus `ev_raw` occupies 12.77 MiB and its `by_session`
  projection 6.15 MiB; `EXPLAIN indexes = 1` reads it through 6 of 115 granules. That is a measured
  48% storage increment for a 19× granule reduction on this point lookup. Force projection use in the
  finalizer benchmark so a silently ignored projection cannot regress the correction path. [ClickHouse projection guidance](https://clickhouse.com/blog/10-best-practice-tips)
  If storage is the limiting resource, benchmark a lightweight `_part_offset` projection introduced in
  modern ClickHouse releases; it can prune rows without copying the full payload, but may be slower for
  a finalizer that needs every session column. [ClickHouse lightweight projections](https://clickhouse.com/blog/projections-secondary-indices)
  recommends validating usage rather than assuming it.
- Do not call `OPTIMIZE FINAL` as a correctness mechanism. Replacing/Aggregating merges are asynchronous;
  source-aware grouping or `FINAL` is a read-time choice, while the delta ledger must be correct before
  merges. [ClickHouse's production guidance](https://clickhouse.com/blog/common-getting-started-issues-with-clickhouse)
  makes the same distinction.
- Incremental MVs are excellent for stateless, per-insert rollups, but session state belongs in the
  finalizer. Each MV/projection adds write work and part pressure; recent ClickHouse field reporting
  describes how repeated full-session refreshes became a runaway workload at scale. [Replo's incident](https://clickhouse.com/blog/replo)
- Expose separate SLOs: ingestion p99 lag, event-time watermark lag, late-correction backlog, correction
  age, duplicate rate, invalid state-transition rate, active parts, merge backlog, and query p95/read
  bytes. A fast dashboard with an old watermark is not correct enough for an operational metric.

### Aggregation algebra: what can and cannot be rolled up

The signed delta ledger is a range-add representation: grouping selected dimensions first and then taking
the hour-local running sum gives the same curve as summing their individual curves. This makes the minute
values and the **integral** (`sum of active-session minutes`) additive. A minute-weighted average is then
the integral divided by the common zero-filled minute grid.

Peak is different. For two dimension series `a(t)` and `b(t)`, in general
`max_t(a(t) + b(t)) != max_t a(t) + max_t b(t)`. If one platform peaks at 10:05 and another at 10:45,
summing their stored hourly maxima invents simultaneous viewers. This is a common OLAP-rollup trap: systems
such as Druid make ingestion granularity and rollup explicit, but a metric's merge algebra still determines
whether it remains exact. [Druid granularity](https://druid.apache.org/docs/latest/querying/granularities/)
[Druid aggregation semantics](https://druid.apache.org/docs/latest/querying/aggregations/)

Therefore the current `cc_minute_delta` remains the authority for arbitrary filtered peaks. An hourly
integral rollup is a later safe optimisation for full-hour totals and averages; an hourly peak table is
correct only if it is materialised at the **same grouping cuboid** the query requests. Benchmark shapes,
not intuition, decide whether a small number of such cuboids repay their write and storage cost. See
[ADR 0015](adr/0015-filtered-peak-is-not-additive.md).

## Practitioner cross-checks

[Uber's production sessionizer](https://www.uber.com/en-GB/blog/sessionizing-data/) is explicitly a
state machine with state expiration, not a grouping trick. Its Kappa architecture retains a backfill
path for late and out-of-order input. Production practitioners also consistently call out late events,
duplicates, schema drift, and backpressure as the failures that emerge after a happy-path stream works;
the [data-engineering discussion](https://www.reddit.com/r/dataengineering/comments/1tcqtz5/common_challenges_in_streaming_data_pipeline/)
is anecdotal rather than authoritative, but matches the risks measured above.

## Cross-system lessons, applied selectively

- Druid makes late-data replacement explicit through versioned segment “overshadowing.” The equivalent
  here is a versioned session snapshot plus signed delta difference: a reader must have one current
  version, never a mixture of old and new output. [Druid task semantics](https://druid.apache.org/docs/latest/ingestion/tasks/)
  are useful design precedent, not a reason to add Druid to this project.
- A stateful external processor is justified only when tail-session state or lateness exceeds what a
  bounded ClickHouse finalizer can safely handle. Uber ran a state machine with expiry rather than
  relying on stateless grouping; use that as the 100x evolution path.
- The ingestion system must expose rejected, duplicate, and late counters alongside throughput. Druid’s
  production metric vocabulary explicitly includes processed, duplicate, unparseable, and thrown-away
  records; the same observability categories belong in ClickStack here. [Druid ingestion metrics](https://druid.apache.org/docs/latest/operations/metrics/)

`tools/audit-data.sh` makes the highest-risk contract checks reproducible for the unseen file. It is a
gate before selecting a watermark or accepting a session-level dimension as stable.

## The right algorithm is a sweep-line ledger, not an interval index

This metric is an **interval-stabbing count**: at each requested minute, count the active intervals that
contain that minute. A generic interval tree is useful when a service must find arbitrary intervals by
point, but it is the wrong physical primitive for this workload: the dashboard needs an aggregate over
many intervals, and every correction must also update that aggregate. The established transformation is
a difference array / sweep line: write `+1` at an interval's first active minute and `-1` immediately
after its last active minute; ordered cumulative sum reconstructs exact concurrency. This is also why
late interval correction is naturally expressed as a signed *set difference* between old and new
intervals, not as an overwrite of a materialized total.

For ClickHouse, clip each interval at hour boundaries before emitting the two markers. A query then
reads only the requested hour partitions and computes a short ordered scan; an update changes at most
two markers per hour segment. The cost is proportional to hours touched, not minutes covered. Measured
on this data, the hour split adds only 8.3% boundary rows, which is far cheaper than expanding every
session to one row per minute. It also avoids a global running sum state crossing partition boundaries.
The same lower-bound intuition appears in interval-intersection research such as
[BITS](https://arxiv.org/abs/1208.3407): do work near the actual overlaps rather than enumerating a
large dense universe. BITS is not a direct implementation dependency; the adopted method here is the
much simpler sweep-line specialization.

There are three distinct algorithms, and conflating them is a common source of silently wrong systems:

| Stage | Algorithm | State needed | Exactness boundary |
|---|---|---|---|
| Event interpretation | per-session finite-state machine plus gap segmentation | ordered events for one session | corrected whenever a late event changes a session snapshot |
| Serving aggregate | hour-clipped signed delta ledger plus ordered cumulative sum | additive markers only | exact for the current finalized snapshot set |
| Live tail | same FSM over a bounded mutable window | session snapshots and ingestion watermark | provisional until watermark passes |

This separation is a practical application of the Dataflow distinction between event-time correctness,
processing-time progress, and a chosen latency/cost policy. Watermarks decide when a session snapshot
is *stable enough to seal*; they never make the underlying event-time rule less strict. See
[The Dataflow Model](https://research.google/pubs/the-dataflow-model-a-practical-approach-to-balancing-correctness-latency-and-cost-in-massive-scale-unbounded-out-of-order-data-processing/)
and [Flink's session-window documentation](https://nightlies.apache.org/flink/flink-docs-stable/docs/dev/datastream/operators/windows/#session-windows), which also highlights that a late event may bridge and merge prior sessions.

## When to keep ClickHouse-only, and when to introduce a stream processor

The correct question is not whether a streaming framework is more sophisticated; it is whether the
required mutable state is larger or more frequent than the bounded ClickHouse finalizer can own. Keep
the current ClickHouse-only design while the finalizer can re-read one session through `by_session`,
late corrections are rare and observable, and dashboard freshness can tolerate the selected watermark.
It has the smallest operational surface and keeps raw, correction ledger, and serving data in one
auditable system.

| Trigger / requirement | Best architecture | Why | What remains in ClickHouse |
|---|---|---|---|
| Seconds-to-minutes freshness; bounded correction volume | Scheduled finalizer + exact tail | Least machinery; deterministic replay from raw | raw, snapshots, signed delta ledger, dashboard serving |
| High-cardinality live sessions; frequent out-of-order input | Flink keyed state machine | Per-key state, event-time timers, checkpoints, late-output handling | durable raw and serving deltas / aggregates |
| SQL-first continuous joins and retractable materialized results | RisingWave or Materialize | Native incremental state and differential updates | analytics history / large scans / dashboard export |
| Many independent consumers and source replay | Kafka/PubSub + one of the above | Durable offsets isolate producers from processing | idempotent landing and analytical serving |
| Corrections are very rare but legally/audit important | ClickHouse + immutable correction ledger | Directly explains every changed minute | all authoritative history and correction audit |

Flink documents keyed state and checkpoint-based exactly-once processing; session windows may emit a
new, merged result after a late bridge. That is powerful, but it transfers the operational burden to
checkpoint storage, source offsets, state growth, rescaling, and a correct sink protocol.
[Apache Flink](https://github.com/apache/flink) is the right 100x option, not a free correctness
upgrade. RisingWave offers managed streaming state persisted in object storage, while Materialize’s
incremental engine represents every change as `(data, logical time, diff)`—conceptually the same signed
change algebra as this delta ledger. Those are compelling if the required retraction rate exceeds the
finalizer budget, not merely because their SQL looks convenient.
[RisingWave](https://github.com/risingwavelabs/risingwave) [Materialize arrangements](https://materialize.com/docs/get-started/arrangements/)

Do not mix architectures silently. If an external processor emits the session intervals, it must own
the session snapshot version and the idempotency key for the downstream ledger. ClickHouse should then
receive a committed signed change batch, never an unversioned mix of old and new intervals. “Exactly
once” is end-to-end: source offset, state checkpoint, output batch, and serving read must agree. This
is why Materialize documents progress metadata for exactly-once sinks rather than presenting the sink
as a stateless insert. [Materialize sink semantics](https://materialize.com/docs/sql/create-sink/iceberg/)

## Source contract required before production streaming

The organiser CSV omits an immutable event id and a source partition/offset, so the current model uses
full-payload deduplication only as a measured fallback. A production source must add the fields below.
Without them, “late”, “duplicate”, and “replay” are guesses rather than states that can be audited.

| Field | Why it is non-negotiable | Failure without it |
|---|---|---|
| `event_id` (immutable, producer generated) | exact dedupe and correction identity | two real equal payloads can be collapsed, or a retry can be double-counted |
| `session_incarnation_id` | distinguishes a reused session id from a long-lived session | old background state can poison a new playback instance |
| `player_instance_id`, `state_scope` | identify what a background/pause transition governs | one process event can be wrongly applied to unrelated sessions |
| `event_time` and `producer_time_zone` | business chronology | ambiguous local time / DST and device-clock interpretation |
| `producer_sequence` per session | deterministic ordering of same-time state transitions | ties depend on physical arrival order |
| `source_partition`, `source_offset`, `ingest_batch_id` | replay checkpoints and forensic trace | cannot prove what a finalizer run consumed |
| `schema_version` | safe evolution and dead-letter routing | a new enum/column silently changes state semantics |
| `ingested_at` at first durable landing | measured lateness and watermark policy | cannot tune freshness versus completeness |

Treat raw landing as a bitemporal fact: `event_time` answers when a viewer action happened, and
`ingested_at` answers when the system learned it. Never overwrite either. A correction should add a
new source fact and a new signed serving batch; it must not rewrite evidence of the prior belief.
Practitioners independently converge on durable raw landing, idempotency, checkpoints, lag monitoring,
and safe replay as the first defenses against streaming failure. That Reddit evidence is anecdotal, not
architectural authority, but it is a useful failure-mode cross-check.
[r/dataengineering discussion](https://www.reddit.com/r/dataengineering/comments/1tcqtz5/common_challenges_in_streaming_data_pipeline/)

### Exactly once is a recovery protocol, not an engine setting

The current finalizer is intentionally an append-only **replacement-state** protocol, but the future live
ingestion boundary needs the same discipline. The official ClickHouse Kafka connector makes the failure
sequence concrete: for each topic partition it records an offset range as `BEFORE`, performs a deterministically
reconstructable insert, then records `AFTER`; a retry after an uncertain insert uses block deduplication and
the same range rather than guessing. [ClickHouse Kafka Connect design](https://github.com/ClickHouse/clickhouse-kafka-connect/blob/main/docs/DESIGN.md)

This gives the required production shape for this project:

```
partition offset range + immutable batch id
    → durable BEFORE / fenced owner
    → idempotent raw landing
    → durable AFTER / consumed range
    → per-partition finalizer checkpoint
```

A scalar `max(ingested_at)` is a local CSV-replay convenience, not the eventual source cursor. Partitioning
must also follow the state key: Pinot’s upsert documentation requires an input stream partitioned by the
primary key and notes that equal comparison timestamps are unordered. That independently supports this
project’s requirement for `(session incarnation, producer sequence)` rather than using event time as a
tie-breaker. [Pinot upsert semantics](https://docs.pinot.apache.org/data-ingestion/upsert-and-dedup/upsert)

Beam makes the complementary finality point: late data must have an explicit allowed-lateness and trigger
policy; otherwise a completed window discards it. The bounded exact tail is our provisional pane, and the
session-diff correction is the late pane. [Beam late data and triggers](https://beam.apache.org/documentation/programming-guide/)

## Lifecycle identity and schema-evolution risk

The supplied corpus passes the current lifecycle probe: **zero** `video_session_id` values have more than
one `session_start_epoch`, and no event precedes its declared start. That does not make `video_session_id`
a durable state key. A reused id can inherit an old background, pause, or terminal transition and suppress
an unrelated playback lifecycle. [ADR 0010](adr/0010-session-incarnation-is-state-key.md) therefore makes
`session_incarnation_id` a source-contract requirement and treats detected reuse as quarantinable bad input.

Schema evolution must be treated with the same caution as event-time evolution: an unknown state event is
not harmless metadata if it changes whether a heartbeat is active. Raw landing stores the declared schema
version, routes unknown enums to a dead-letter/audit stream, and lets a replay under a new model version
produce a separately attributable correction run. Iceberg's schema-evolution guidance is useful here as a
general principle: identify fields stably and evolve deliberately, rather than trusting positional schemas.
[Apache Iceberg evolution](https://iceberg.apache.org/docs/latest/evolution/)

## Product innovation: proof-carrying concurrency, not just a number

The dashboard should serve a small correctness envelope with every curve, rather than implying that a
fresh-looking integer is final. This turns the difficult engineering into a user-visible advantage and
gives ClickStack a load-bearing role: operators can distinguish *low viewers* from *unknown viewers
because the pipeline is behind*.

```
concurrency result
  ├── value                 2,881
  ├── event_time            2026-07-26T10:56:00Z
  ├── status                sealed | provisional | correcting
  ├── sealed_through        event-time watermark W
  ├── source_high_watermark ingestion timestamp / offset consumed
  ├── model_version         state-gate-v2 + threshold hash
  ├── reconciliation_run    raw-vs-serving proof run id
  └── correction_age        age of oldest unresolved late event
```

`sealed` means the value is from a reconciled signed-delta snapshot below `W`; `provisional` means it
comes from the exact mutable tail and may change; `correcting` means a late-event diff is in flight.
These are semantic states, not UI decorations. A query that spans `W` returns row-level status so a
range peak never silently mixes final and provisional time.

Instrument the finalizer, correction writer, reconciliation run, and query with OpenTelemetry spans;
attach `run_id`, model version, source high-watermark, event watermark, affected-session count, delta
row count, and correction age. The ClickStack panel should alert on (a) no watermark movement while raw
ingest continues, (b) reconciliation failures, (c) correction backlog age, and (d) a large divergence
between the independent baseline and state-gated model. This is materially better than monitoring HTTP
latency alone: it detects a dashboard that is fast but semantically stale.

The archive’s real-time guidance explicitly warns that a live-looking surface can read a table that is
not being correctly updated. This confidence envelope is the answer: it makes freshness, finality, and
proof inspectable. It is a planned serving contract; the historical batch spine already provides its
`model_version` and raw-to-serving reconciliation components, while the watermark fields await the
live finalizer.

The correction baseline also carries an explicit `model_version`. A threshold or state-order change is a
semantic migration, not a routine deploy: the finalizer fails closed until the historical baseline is rebuilt
under the new version. This matters as much as schema migration, because otherwise the same raw event would
be compared to an output produced by different foreground rules.

The model label is now paired with a deterministic hash of the interval, correction, and tail SQL. This
turns a forgotten release-label bump into a safe baseline mismatch instead of a mixed semantic ledger.
One boundary remains deliberately external: concurrent finalizers cannot safely allocate the same logical
sequence through a read-then-insert pattern. [ADR 0014](adr/0014-finalizer-requires-an-external-single-writer-lease.md)
defines the required leader lease and source-offset ownership contract rather than pretending a ClickHouse
table is a distributed lock.

## Bitemporal replay: truth now versus belief then

The correction overlay is a small form of differential dataflow: each marker has a signed change and a
logical run sequence, and a query chooses the latest value at a requested sequence. `query-concurrency.sh
--as-of-run N` now reconstructs the curve that was visible after run `N`; its default is the latest state.
This makes late-correction impact auditable without changing raw facts or copying full daily snapshots.

This is the practical form of the bitemporal distinction in CEDR: event time answers *when viewers watched*;
run sequence/ingestion watermark answers *when the system knew enough to report it*. Differential dataflow
uses the same core representation—data, logical time, and diff—to incrementally maintain outputs. The
project does not adopt that runtime because its correction volume remains bounded, but it adopts the algebra
where it directly improves auditability. [CEDR bitemporal stream model](https://arxiv.org/abs/cs/0612115)
[Differential Dataflow](https://timelydataflow.github.io/differential-dataflow/)
