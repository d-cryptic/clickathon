# IMPROVEMENTS — candidate practices, measured against this workload

> **Summary:** Six ClickHouse practices taken from a mature production deployment in another domain
> were tested against **this** data and service before being adopted. **Four were rejected**, one is
> kept only as a guardrail, and none required a code change. The `argMax`-instead-of-`FINAL` idea was
> the most promising and measured **3–4× slower**. The real value came out of the testing rather than
> the practices: `async_insert` is **already on** by default here, so app-side batching would
> reimplement the server, and **refreshable materialized views work on this service** — validated end
> to end — which is the native answer to our one remaining architectural gap.

**Measured:** 2026-08-01 · ClickHouse Cloud 26.2.1.525 · `sonyliv` · caches disabled per query

---

## Method

Each candidate was run against the real tables with `use_query_condition_cache=0` and
`use_query_cache=0`, best of three. A practice earned from a large deployment is a **hypothesis about
our workload, not a fact about it** — the same rule `docs/VERIFIED.md` applies to inherited numbers.

## Verdicts

| Candidate | Verdict | Why |
|---|---|---|
| `argMax(col, version)` instead of `FINAL` | **REJECTED** | 3–4× slower, 5.7× more bytes read |
| App-side buffer + flush batching | **REJECTED** | `async_insert` already does it server-side |
| External idempotency store for replays | **SUPERSEDED** | the loader now refuses to double a load |
| Guard env-parsed timer values against `NaN` | **NOT APPLICABLE** | we parse no env value into a timer |
| Circuit breaker on consecutive failures | **NOT APPLICABLE** | we have no streaming consumer |
| Never `OPTIMIZE … FINAL` on write | **KEEP AS GUARDRAIL** | we never do it; the trap is real for what comes next |

---

## 1 · `argMax` instead of `FINAL` — rejected

The idea: a `ReplacingMergeTree` read can avoid merge-on-read by grouping on the sort key and taking
`argMax(col, version)`. We read `FINAL` in five places, so this looked like a straight win.

Measured on `session_intervals`, best of three:

| approach | elapsed | rows read | bytes read |
|---|---:|---:|---:|
| `FINAL` | **4.9–9.2 ms** | 30,323 | **485,168** |
| no `FINAL` | 5.0–8.0 ms | 30,323 | 485,168 |
| `argMax` + `GROUP BY` key | **18.4–34.0 ms** | 30,323 | **2,759,393** |

**`FINAL` costs nothing here, and `argMax` costs a lot.** The reason is structural, not incidental:

```
active parts          1
rows                  30,323
distinct (session, interval_start) keys  30,323
duplicate keys        0
```

With one active part and no duplicate keys, `FINAL` has nothing to collapse — it reads the same bytes
as a plain scan. `argMax` instead forces a full `GROUP BY` over every row and must read the version
and endpoint columns to do it, hence 5.7× the bytes.

**The generalisable rule:** `argMax` beats `FINAL` when duplicates are *common* and parts are *many* —
a table under continuous mutation. Ours is rebuilt in one pass and immediately merged, so it is the
opposite case. Re-measure if the model ever moves to incremental in-place updates; the conclusion
would likely flip.

## 2 · App-side buffer + flush — rejected, the server already does it

The practice is a buffer flushed on `BATCH_SIZE` **or** a timer, whichever comes first. That is
exactly the semantics of a setting already enabled on this service:

| setting | value |
|---|---|
| `async_insert` | **1** (on by default) |
| `async_insert_max_data_size` | 104,857,600 (100 MB) |
| `async_insert_busy_timeout_ms` | 1,000 |

Server-side, size-or-timeout, no application state to get wrong. Building our own buffer would
reimplement this **and** move the durability boundary into a process that can die holding data.
Consider `wait_for_async_insert=0` for throughput only if an ingest path ever becomes the bottleneck,
and only knowing it trades an acknowledgement for speed.

## 3 · External idempotency store — superseded

The practice guards a consumer against replaying the same message. Our equivalent defect was that
re-loading the same CSV silently doubled the data. That is now handled in the loader, which **refuses
by default** and requires an explicit `--replace` or `--append`. A refusal needs no extra
infrastructure and cannot itself fail open, which suits a one-shot loader better than a distributed
lock would.

## 4 · Never `OPTIMIZE … FINAL` on write — kept as a guardrail

We never call `OPTIMIZE` (verified: no occurrence anywhere in `sql/` or `tools/`), so there is nothing
to fix. It is recorded because it is precisely the tool someone reaches for when a `ReplacingMergeTree`
read looks stale, and the failure mode is severe: `OPTIMIZE … FINAL` is a **full-table rewrite that
ClickHouse runs serially per table**. Issuing one per write queues them on the per-table merge lock and
saturates the service. The correct fix for a stale read is to read `FINAL` — which, per §1, is free
for us.

**Rule: reads may say `FINAL`; writers must never say `OPTIMIZE`.**

---

## What the testing actually gave us

Neither of these came from the practices. Both came from checking whether the practices were needed.

### Refreshable materialized views work here — validated

`allow_experimental_refreshable_materialized_view = 1` on this service, and it is not merely enabled:

```sql
CREATE MATERIALIZED VIEW rmv REFRESH EVERY 1 MINUTE TO tgt AS
SELECT minute, toUInt64(concurrent) AS c FROM v_concurrency_minute_delta_total;
```

Created in a scratch database, it **populated itself within 8 seconds — 1,579 rows** — with no
external scheduler, no consumer and no application code. Scratch database dropped afterwards.

This is the native answer to the one architectural gap left: *"publish continuously updated
aggregates"*. Today the model is rebuilt by `make model`, so freshness is bounded by how often a human
runs it. A refreshable MV over the existing serving views converts that to a declared interval, with
the refresh interval becoming the freshness SLA and `system.view_refreshes` making lag observable.

It is not free: each refresh re-runs the query, so the interval must be chosen against query cost, and
it does not make the *derivation* incremental — it makes the *publication* automatic. That is still
the difference between "batch-rebuilt when someone remembers" and a stated freshness guarantee.

### Version detail worth having

On 26.2.1.525 `system.view_refreshes` has **no `last_refresh_result` column**. The columns are
`status`, `last_success_time`, `last_success_duration_ms`, `last_refresh_time`, `next_refresh_time`,
`exception`, `retry`, `progress`, `read_rows`, `read_bytes`, `written_rows`, `written_bytes`. Any
monitoring written against the documented-elsewhere name will fail with `Code: 47`.

---

## What did not transfer at all

The source deployment solves attribution — joining identifiers across events within a fixed day
window. Its "attribution window" is `|t1 − t2| ≤ N days`, which is far simpler than our watermark and
carries nothing across. Its schemas are wide `String` tables with no `LowCardinality` and, notably, no
aggregating engines or materialized views anywhere: it queries raw tables. So there is no
pre-aggregation, delta-model or serving-layer precedent to borrow. The overlap is operational
ClickHouse knowledge, not modelling.
