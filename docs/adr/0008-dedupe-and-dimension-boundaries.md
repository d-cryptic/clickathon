# ADR 0008 — Dedupe retry copies and split intervals on serving-dimension drift

> **Summary:** The supplied stream has 4,209 exact duplicate rows and some sessions change platform,
> content, or user identity. Sessionization first removes exact payload retry copies, preserves raw data
> unchanged, and splits an active interval whenever `platform`, `country`, or `content_id` changes. This
> prevents an arbitrary `any()` attribute from corrupting a filtered concurrency result.

**Status** Accepted · 2026-08-01

## Context

`video_session_id` is not a sufficient dimension identity. In the supplied data, 95 sessions span two
platforms and one spans two content ids. Selecting `any(platform)` after grouping a whole session is
nondeterministic across parts and falsely assigns activity to one filter bucket.

There is no source event id. 4,209 rows are byte-for-byte duplicates across all delivered event fields,
including 84 background and 138 pause markers. They are best interpreted as retry copies, but raw must
retain them for forensic replay.

## Decision

The derivation reads a `DISTINCT` projection of the delivered payload, never mutates `ev_raw`, and
starts a new active interval when an eligible heartbeat changes a serving dimension. `user_id`, app, and
player version are retained for audit but do not define dashboard buckets; user-level concurrency is a
separate metric with different distinct-count arithmetic.

## Consequences

- A session can contribute to multiple platform/content buckets over its lifetime, but never twice in a
  single interval.
- A real upstream event that is indistinguishable from a retry copy will be collapsed. The only complete
  remedy is an organiser-provided immutable event id; surface this as a data-contract requirement.
- A serving-dimension change is also an immediate end cap for the preceding interval. Splitting without
  this cap grants the old bucket tail credit after the new bucket begins, briefly double-counting a
  single session across dimensions.
- Late correction snapshots must use the same payload-dedupe and dimension-boundary semantics.
