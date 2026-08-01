# ADR 0010 — Session lifecycle identity is the state-machine key

> **Summary:** `video_session_id` alone is sufficient only while it is globally lifecycle-unique. The
> supplied corpus has zero ids with multiple `session_start_epoch` values, but that is evidence, not a
> production contract. Live input must carry `session_incarnation_id`; otherwise ingestion audits and
> quarantines reused ids rather than joining independent foreground/pause histories. Status: accepted,
> 2026-08-01.

**Status** Accepted · 2026-08-01

## Context

The foreground state machine is keyed by `video_session_id`. If an SDK reuses that id after an app restart,
an old `AppBackgrounded`, pause, terminal event, or late heartbeat can alter the next viewing lifecycle.
That failure is worse than a missing row: it is a plausible but wrong concurrency curve and is difficult to
spot after aggregation.

The supplied data repeats a `session_start_epoch` on every event. The audit found zero video ids with more
than one declared start, and no event before its declared start. This lets the benchmark model keep its
simple key, but does not prove a future producer contract.

## Decision

Require an immutable `session_incarnation_id` generated at playback creation. The state key for production
is `(video_session_id, session_incarnation_id)`, while the visible session id remains a reporting attribute.
Until that field exists, `tools/audit-data.sh` measures multiple `session_start_epoch` values per video id;
any non-zero result is a data-contract incident, not an invitation to silently merge the lifecycles.

## Consequences

- A late event must carry the same incarnation id as its original lifecycle or be quarantined.
- A client clock reset is not a valid reincarnation signal; server/producer lifecycle identity is required.
- The finalizer's point lookup and correction key adopt the compound key when the source contract arrives.
- This is compatible with Flink keyed state, Kafka partitioning, and the current ClickHouse finalizer; it
  changes identity semantics, not the foreground interval algorithm.
