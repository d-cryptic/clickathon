# ADR 0013 — Reject ambiguous source before sessionization

> **Summary:** Materialization runs a source-contract preflight before touching derived tables. It rejects
> ambiguous lifecycle reuse, invalid identity/timestamps, unknown event types, same-time serving-dimension
> conflicts, and dangling content references. Payload retries and repeated terminal events remain warnings
> because the current derivation handles them deterministically. Status: accepted, 2026-08-01.

**Status** Accepted · 2026-08-01

## Context

The state machine can only be correct when it has a unique lifecycle key and a deterministic ordering for
each event. Raw ingestion is intentionally append-only, which preserves evidence but does not make every
input safe to aggregate. Silently accepting an ambiguous session id or two conflicting platform/content
values at the same event time produces a plausible curve with no honest correctness interpretation.

## Decision

`tools/validate-source-contract.sh` runs before `tools/materialize.sh --replace`. It fails closed on:

- empty identity or epoch timestamps;
- an event timestamp more than five minutes ahead of its first durable ingestion time;
- event types outside the delivered protocol;
- events without a matching content dimension;
- a content id with conflicting title, video-type, or category definitions;
- events before their declared session start;
- one `video_session_id` carrying multiple `session_start_epoch` lifecycles; and
- tied timestamps that disagree on platform, country, or content id.

It reports but does not reject exact payload retries and duplicate terminal markers. The derived model uses
payload-level `DISTINCT`, and `VideoSessionEnd` is already an idempotent hard stop. The supplied corpus
passes with zero hard violations, 4,209 retry copies, and four sessions with a repeated terminal marker.

## Consequences

- The unseen file cannot quietly broaden the model's meaning.
- The five-minute future-clock allowance is a quarantine boundary, not a lateness window: old events are
  corrected through the normal replay path, while a client clock that claims a future action is a source
  integrity incident.
- `content_dim` is currently a static snapshot. `ReplacingMergeTree` without a source version may choose
  arbitrarily between conflicting rows, so the gate prohibits a conflicting dimension rather than treating
  `FINAL` as a correctness mechanism.
- A real source needs immutable event identity and a producer sequence/partition offset; timestamp-only
  `ingested_at` is insufficient as a durable cursor.
- When lifecycle reuse becomes legitimate, replace the rejection with an upstream `session_incarnation_id`
  and migrate every state/correction key together, as required by ADR 0010.
