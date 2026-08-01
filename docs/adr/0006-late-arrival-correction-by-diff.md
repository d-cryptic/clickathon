# ADR 0006 — Late arrivals use published per-session correction state

> **Summary:** A late event is corrected by re-deriving one session, but the old result cannot be
> reconstructed from mutable serving aggregates alone. Keep a bootstrap per-session marker snapshot,
> stage a complete replacement correction for every touched marker, and expose it only after a run-log
> publication record. This avoids `ALTER ... UPDATE`, avoids an unsafe cross-table transaction, and
> remains exact through retries. Status: accepted, 2026-08-01.

**Status** Accepted · 2026-08-01

## Context

An event can arrive after its event-time watermark. Rebuilding a day is too expensive and mutating
`cc_minute_delta` rewrites parts asynchronously. The first design proposed appending `new - old` directly
to the aggregate. That is incomplete: raw data contains the new event, not the old derived marker set, and
the local non-replicated setup cannot atomically write a correction and its checkpoint together.

`ReplacingMergeTree` does not solve this on its own. Deduplication happens during background merges, so a
plain read can observe duplicate state unless it pays for `FINAL` or performs a versioned aggregation. The
dashboard must not rely on either an eventual merge or experimental multi-table transactions.

## Decision

The historical backfill remains the compact baseline in `cc_minute_delta`. `session_delta_base` stores the
same hour-clipped marker contribution for each session. A finalizer run re-derives every session touched in
an overlapping ingestion-time window and calculates:

```
target correction = current session markers - bootstrap session markers
```

For each `(session, dimensions, minute)`, it stages the entire target value, including zero tombstones. A
read sees only rows whose run has reached `published` in `finalizer_run_log`, and chooses
`argMax(correction_delta, run_sequence)`. It then adds that current correction state to the compact baseline.

Run phases are immutable log rows:

1. `prepared` records the source range and event-time watermark.
2. The correction marker set is inserted into the staging table.
3. `staged` records the observed marker count.
4. `published` makes the run visible to dashboard queries.

A crash before step 4 leaves an invisible run. `tools/finalize.sh --resume RUN_UUID` repeats the deterministic
staging insert and then publishes it. Repeated rows for the same `run_sequence` are harmless because the
serving query takes the same complete target value with `argMax`; insert deduplication is only a bounded
storage optimization, not a correctness dependency.

## Consequences

- The correction state is a small query-time overlay. Its cost is proportional to corrected session markers,
  not the base event stream. Monitor it; move to a stream processor if correction state stops being small.
- The scheduler must provide a single writer. The run log detects an unfinished local run, but it is not a
  distributed lease or a substitute for an orchestrator lock.
- `source_from` overlaps the prior high-watermark. This intentionally reprocesses boundary arrivals because
  the organiser source lacks a monotonically unique ingestion offset. The result is idempotent state, not an
  additive retry.
- The event watermark is retained as freshness/completeness metadata. A correction older than it is valid and
  becomes visible through the same run; alert on its age rather than silently discarding it.

## Rejected alternatives

- **`ALTER TABLE ... UPDATE`:** asynchronous part rewrites and read-after-write ambiguity.
- **Append `new - old` directly to `cc_minute_delta`:** a process crash between the write and checkpoint can
  repeat the difference and corrupt the curve.
- **`ReplacingMergeTree` plus a normal read:** eventual background merges make correctness timing-dependent.
- **Experimental multi-table transactions:** require Keeper and are not the deployed local baseline.
