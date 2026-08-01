# ARCHITECTURE — the concurrency model

> **Summary:** Raw events → active intervals (heartbeat-gap derived) → **hour-clipped** minute deltas per
> dimension combination → concurrency as a running sum within each hour. Serving is **one exact tier**.
> Incremental publication ([ADR 0013](adr/0013-continuous-publication-by-incremental-finalizer.md)) maintains
> `session_intervals` + `cc_minute_delta` **only** — the hour/day and user tiers still rebuild in batch.
> The hot tier of [ADR 0004](adr/0004-two-tier-lambda-serving.md)/[0005](adr/0005-heartbeat-lease-semantics.md)
> is **declined**; `cc_minute_stateless` is the session-independent half of the mandated comparison.
> Peak is never stored — not summable across dimensions; hour-clipping makes it summable across time. The
> delta table is append-only; the finalizer's one mutation is a lightweight `DELETE` pruning superseded interval rows.

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

**2 · `session_intervals`** — one row per contiguous *active* range. Derived by walking a session's
events in time order and closing an interval when the heartbeat gap exceeds `HEARTBEAT_GAP_S`.
`ReplacingMergeTree(build_version)` — a monotonic version — so a re-derivation replaces rather than
duplicates. *(Versioning on `interval_end` was proven wrong and fixed at `388a845`: a provisional
interval's 60 s tail grace can overshoot the true end, so the stale row won forever.)* `is_open` marks
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

**5 · `cc_minute_stateless`** — the session-independent model, straight from `ev_raw` via `mv_stateless`.
Any heartbeat in a minute means that session was active in that minute; no session reconstruction.
**`uniqExact`, never `uniq`** — HLL's 1–2% error is a silent correctness bug against an exact ground
truth. Reads **2,894** at the peak minute against the session-aware **2,917**; that pair *is* the
comparison the statement mandates.

> **`cc_minute_hot` — the lease hot tier — is NOT built, and is not pending either.** Heartbeats renew
> straight through a `pause` (0.756/min, inside `LEASE = 150 s`), so leases would count paused time as
> watching: 834 h of exposure against a 1,949 h answer
> ([ADR 0005](adr/0005-heartbeat-lease-semantics.md)). Its only job was to answer minutes newer than
> the watermark while the sealed tier lagged 40 minutes; with the finalizer below running every minute
> that lag is seconds, so the tier buys sub-minute freshness at the price of a same-order error.
> Declined in [ADR 0013](adr/0013-continuous-publication-by-incremental-finalizer.md).

**6 · `session_dirty` + the finalizer** — how the aggregates stay current. `mv_session_dirty` fires on
every INSERT into `ev_raw` and records which sessions that insert touched, stamped with **ingest**
time. `tools/publish.sh` claims what has arrived since its cursor, re-derives **only those sessions**,
and appends `−deltas(old) + deltas(new)`. `v_cc_publish_lag` is the freshness metric; `v_cc_watermark`
still reports event-time staleness. See [ADR 0013](adr/0013-continuous-publication-by-incremental-finalizer.md)
and `evidence/publish.txt`.

**Scope of the finalizer — read this before quoting "continuously updated".** It maintains
`session_intervals` and `cc_minute_delta` only; `sql/12_publish.sql` and `tools/publish.sh` contain
**zero** references to `cc_hour_agg` or `cc_user_minute`, so hour/day peaks and user concurrency still
come from the batch rebuild (`tools/build-model.sh`) — see `docs/WORKTREE_QUEUE.md` Q2 (ADR 0015,
pre-assigned). Each run also schedules one lightweight `DELETE` pruning interval rows superseded by
`build_version`; the pipeline is append-only *except* for that prune. And on the graded `sonyliv`
database the publisher is **installed but has never committed a run** (publish cursor at epoch,
`last_committed_run = 0`, re-verified read-only 2026-08-01) — every live number there comes from
batch rebuilds.

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

**One mechanism, not three.** Every arrival class is a session that received events; the finalizer
re-derives it and appends the difference ([ADR 0013](adr/0013-continuous-publication-by-incremental-finalizer.md)).

| Arrival | Mechanism | Measured |
|---|---|---|
| In normal order | claimed from `session_dirty`, re-derived, diffed | 5 sessions in 4.6 s |
| Still open (no `VideoSessionEnd`) | dirty on every batch, so re-derived every batch — no special path | included above |
| **Straggler, older than `W`** | *the same path.* Correction-by-diff does not care how old the event is | 1 session in **3.4 s**, 0 of 1,579 minutes wrong |
| Replay / forced correction | `−deltas(X) + deltas(X) = 0`, so it is a no-op | 200 sessions, 0 minutes moved |

This is why the **watermark is no longer a gate**. ADR 0004 needed `W = 2400 s` because a sealed minute
had no way back; correction-by-diff *is* the way back, so nothing has to be held. `W` survives as a
freshness *label*. The metric to instrument in ClickStack is now `v_cc_publish_lag` — **ingest-time**
staleness and queue depth — alongside `v_cc_watermark`'s event-time view.

The proof is `evidence/publish.txt` (`tools/publish-test.sh`): at every stage the two tables the
finalizer maintains — `session_intervals` and `cc_minute_delta` — are byte-identical to a
from-scratch rebuild, in a scratch database, including the case where a straggler makes an
`interval_start` vanish. The test compares nothing else; "byte-identical" is proven for those two
tables only.

## Trade-offs to defend

| Choice | Alternative | Why ours |
|---|---|---|
| Interval → delta | per-minute explosion | O(intervals) vs O(sessions × minutes) |
| Hour-clipped deltas | unclipped | removes the carry-in scan-from-`t=0`; makes hour-grain peak pre-aggregable (day peak reads 24 rows/combo, not 1,440) |
| Heartbeat gaps | bg/fg pairing | bg/fg are not guaranteed; 379 unmatched in the sample — **conditional on the gating measurement below** |
| **One exact tier, published incrementally** | two-tier lambda with a lease hot tier | the hot tier's only job was covering the sealed tier's 40-minute lag; a per-minute finalizer removes the lag, and the tier would have cost 834 h of paused time counted as watching ([ADR 0013](adr/0013-continuous-publication-by-incremental-finalizer.md)) |
| **Change-log MV** (`session_dirty`) | scan `ev_raw` per batch for what moved | ADR 0006's "compare max event ts per session" is O(history) every run — the hackathon-size shape the statement warns about. An MV sees only the current insert block, which is exactly what needs re-deriving |
| Correction by diff | `ALTER … UPDATE` / partition rebuild | exactly as correct as a rebuild, of one session; cost scales with stragglers, not history — **measured 3.4 s and 11.6% of `ev_raw` for a 46-minute-late straggler** |
| Prune superseded intervals | leave them to `FINAL` | `ReplacingMergeTree` replaces a key, it cannot delete one; a straggler bridging a gap makes an `interval_start` vanish and the orphan would compound into the next run's negation |
| Dimension-first key **on the serving tables** | time-first | dashboards filter then range-scan; measured 122× on a comparable A/B |
| Time-bucket-first key **on `ev_raw`** | session-id-first | measured 17.3× better on the dashboard shape, identical on the full interval rebuild ([ADR 0002](adr/0002-order-by-time-bucket-then-platform.md)) |
| `PROJECTION` by `video_session_id` | reverting ADR 0002 | our finalizer and correction paths are point lookups by session; a projection restores them without losing the 17.3×. **Still not shipped** — but re-measured on the finalizer's real query shape it takes a one-session read from 11.6% of `ev_raw` to **0.9%**, for +91% storage. The earlier "1.00×" was measured on a different shape; see [ADR 0013](adr/0013-continuous-publication-by-incremental-finalizer.md) |

## The premise this all rests on

**Measured** (GATE ①, [ADR 0007](adr/0007-gate-answers-pause-needs-explicit-handling.md)): heartbeats
drop 100× while the app is backgrounded — 4.72/min active vs 0.047/min backgrounded — so gap detection
stands. What remains unverifiable from the data is which gap/tail/pause policy the **private ground
truth** assumed (`GAP_S`, `TAIL_S`, the unclosed-pause rule, and the inclusive minute-boundary
convention); each is a [doubts/](../doubts/) dossier or `docs/WORKTREE_QUEUE.md` Q3, and a wrong guess
is silently wrong on every answer.

One semantic limit to state plainly: only exact lowercase `pause`/`resume` sub-events and
`VideoSessionEnd` (for `is_open`) carry explicit meaning in the derivation. `VideoSessionStart`,
`VideoPlay`, `AppBackgrounded`, `AppForegrounded` and `VideoError` participate **only** as generic
timestamps in the gap arithmetic — an observed `AppBackgrounded` does not itself close active state
and can even earn tail grace. Deliberate (bg/fg are not guaranteed to pair), but it is a modeling
policy, not a fact from the data dictionary — see
[docs/codex-validation/002.md](codex-validation/002.md) §4.

Full reasoning, with diagrams for every step above:
[docs/artifacts/2026-08-01-concurrency-model-deep-dive.html](artifacts/2026-08-01-concurrency-model-deep-dive.html).
