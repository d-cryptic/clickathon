-- ============================================================================
-- 45_user_concurrency.sql — USER-LEVEL concurrency, a distinct count, NOT a delta.
--
-- WHY this is not "cc_minute_delta with user_id swapped in":
-- cc_minute_delta works because a SESSION is active in exactly one interval at
-- a time, so +1/-1 deltas are additive and a running sum is a valid count. A
-- USER is not exclusive that way: one user can run several sessions at once
-- (measured on session_intervals — see verification below, 772 users with >1
-- concurrent-capable session, one outlier user with 297 sessions total).
-- Summing per-session deltas grouped by user_id would count that user once per
-- overlapping session — the same 9x over-count class CONVENTIONS.md already
-- warns about for "never sum a distinct count". User concurrency is inherently
-- a SET-CARDINALITY question per minute: "how many distinct user_id are active",
-- which is exactly what uniqExact(State/Merge) exists for, and exactly what a
-- SimpleAggregateFunction(sum, ...) delta CANNOT express.
--
-- Grain, dims and sort key deliberately mirror cc_minute_stateless /
-- cc_minute_delta: (platform, country, content_id, minute), dims first per
-- CONVENTIONS.md (dashboards filter then scan a time range). Populated from
-- session_intervals (the accurate, gap+pause-derived model), not from raw
-- heartbeats — session_intervals is already the thing that excludes background
-- and paused time; re-deriving that here would duplicate H1/H2 logic and could
-- drift from it.
--
-- SimpleAggregateFunction would be wrong here (that's for SUMS); a distinct
-- count needs the full AggregateFunction(uniqExact, String) state, per
-- CONVENTIONS.md "Never sum a distinct count" and ADR 0005 (uniqExact, not the
-- HLL-estimator uniq, against an EXACT private ground truth).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- The serving table. AggregateFunction(uniqExact, String) state per
-- (dims, minute) — mergeable, idempotent, and cheap to store relative to a
-- per-minute explosion of raw user_ids.
--
-- ORDER BY (platform, country, content_id, minute): identical reasoning to
-- cc_minute_delta / cc_minute_stateless — dashboards filter on the dims first,
-- then range-scan minute; a coarse dim prefix prunes because it repeats.
-- PARTITION BY day so a day's worth of intervals lands and merges together,
-- matching every other table in this model.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cc_user_minute
(
    minute       DateTime,
    platform     LowCardinality(String),
    country      LowCardinality(String),
    content_id   Int64,
    active_state AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMMDD(minute)
ORDER BY (platform, country, content_id, minute)
SETTINGS min_bytes_for_wide_part = 0;

-- ---------------------------------------------------------------------------
-- Incremental absorption: any FUTURE insert into session_intervals (the
-- finalizer's normal run, or a straggler correction re-deriving one session)
-- flows into cc_user_minute automatically. Per the vendored rule
-- `query-mv-incremental`: an incremental MV does NOT retroactively cover data
-- already in the source table, so a one-time backfill (below) is required in
-- addition to this MV, not instead of it.
--
-- Expanding an interval into its covered minutes here is the same arrayJoin
-- shape as v_concurrency_minute_intervals in 20_views.sql — row-level, no
-- cross-block state, so (unlike interval DERIVATION itself, ADR 0004) this is
-- a legitimate streaming MV.
--
-- Re-processing: session_intervals is ReplacingMergeTree(interval_end), so a
-- late heartbeat that EXTENDS an interval arrives as a new inserted row with
-- the same (video_session_id, interval_start) and a longer interval_end. The
-- MV fires again on that new row's raw insert (MVs see inserted blocks, not
-- the post-merge/FINAL view) and adds only the NEWLY covered minutes' worth of
-- user_id to the uniqExact state. Because uniqExact state merging is a SET
-- UNION, re-adding a user_id already present in a bucket is a no-op — safe by
-- construction, unlike the delta model where a replay doubles every number.
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_user_minute TO cc_user_minute AS
SELECT
    toDateTime(m) AS minute,
    platform,
    country,
    content_id,
    uniqExactState(user_id) AS active_state
FROM
(
    SELECT
        user_id, platform, country, content_id,
        arrayJoin(range(
            toUInt32(toStartOfMinute(interval_start)),
            toUInt32(toStartOfMinute(interval_end)) + 1,
            60
        )) AS m
    FROM session_intervals
)
GROUP BY minute, platform, country, content_id;

-- ---------------------------------------------------------------------------
-- One-time backfill for every interval already in session_intervals as of
-- when this script first runs (the MV above only sees rows inserted AFTER it
-- exists). Reads FINAL so a superseded (extended) interval row is not double
-- counted here — irrelevant for the uniqExact set union regardless, but FINAL
-- keeps this backfill computing over the same "current truth" the rest of the
-- model reads.
--
-- Safe to re-run: identical reasoning as the MV above — uniqExact state union
-- is idempotent per value, so replaying this INSERT adds duplicate parts that
-- merge to the same distinct-count result, not a doubled one. (It does waste
-- storage/merge work on a re-run; this is a one-time backfill, not a
-- resettable build step like cc_minute_delta.)
-- ---------------------------------------------------------------------------
INSERT INTO cc_user_minute
SELECT
    toDateTime(m) AS minute,
    platform,
    country,
    content_id,
    uniqExactState(user_id) AS active_state
FROM
(
    SELECT
        user_id, platform, country, content_id,
        arrayJoin(range(
            toUInt32(toStartOfMinute(interval_start)),
            toUInt32(toStartOfMinute(interval_end)) + 1,
            60
        )) AS m
    FROM session_intervals FINAL
)
GROUP BY minute, platform, country, content_id;

-- ---------------------------------------------------------------------------
-- Serving views — merge state to a plain number, once, here (same rationale
-- as 20_views.sql: a chart tool cannot read an AggregateFunction column).
-- ---------------------------------------------------------------------------

-- Per dimension combination. Grain: one row per (minute, platform, country,
-- content_id). Do NOT sum `concurrent_users` across dims for the same reason
-- v_concurrency_minute_stateless warns about: a user active under two
-- content_ids in the same minute would be counted twice. Filter, then read.
CREATE OR REPLACE VIEW v_user_concurrency_minute AS
SELECT
    minute,
    platform,
    country,
    content_id,
    uniqExactMerge(active_state) AS concurrent_users
FROM cc_user_minute
GROUP BY minute, platform, country, content_id;

-- The headline user curve: total distinct users active per minute, all
-- dimensions collapsed. Re-merges the underlying states rather than summing
-- the per-dimension view above — uniqExactMerge across ALL states for a
-- minute deduplicates a user active on several dims/sessions at once; SUM()
-- would not, and would reproduce exactly the over-count this file exists to
-- avoid.
CREATE OR REPLACE VIEW v_user_concurrency_minute_total AS
SELECT
    minute,
    uniqExactMerge(active_state) AS concurrent_users
FROM cc_user_minute
GROUP BY minute;
