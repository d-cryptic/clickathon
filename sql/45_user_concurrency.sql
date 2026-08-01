-- ============================================================================
-- 45_user_concurrency.sql — USER-LEVEL concurrency, a distinct count, NOT a delta.
-- cc_user_minute is a ReplacingMergeTree(computed_at) of uniqExact STATES keyed
-- (platform, country, content_id, minute): a re-derivation REPLACES a bucket,
-- so a user CAN be retracted from a minute — the thing the retired MV's set
-- union could never do (ADR 0016). One canonical INSERT below re-derives
-- buckets; tools/publish.sh scopes it to a batch's touched minutes, and
-- tools/build-model.sh runs it whole after a TRUNCATE. Views read FINAL.
--
-- WHY this is not "cc_minute_delta with user_id swapped in":
-- cc_minute_delta works because a SESSION is active in exactly one interval at
-- a time, so +1/-1 deltas are additive and a running sum is a valid count. A
-- USER is not exclusive that way: one user can run several sessions at once
-- (measured on session_intervals — 772 users with >1 concurrent-capable
-- session, one outlier user with 301 sessions total). Summing per-session
-- deltas grouped by user_id would count that user once per overlapping session
-- — the same 9x over-count class CONVENTIONS.md already warns about for "never
-- sum a distinct count". User concurrency is inherently a SET-CARDINALITY
-- question per minute, which is exactly what uniqExact(State/Merge) exists
-- for, and exactly what a SimpleAggregateFunction(sum, ...) delta CANNOT
-- express (uniqExact, not the HLL-estimator uniq, against an EXACT private
-- ground truth — ADR 0005).
--
-- WHY ReplacingMergeTree AND NOT AggregatingMergeTree + MV (ADR 0016).
-- The previous shape — AggregatingMergeTree fed by an incremental MV on
-- session_intervals — merges uniqExact states by SET UNION. Union has no
-- inverse: it can ADD a user to a (minute, dims) bucket but can never RETRACT
-- one whose only covering interval was superseded (shrunk, re-attributed, or
-- vanished). That is why tools/build-model.sh had to TRUNCATE this table on
-- every full rebuild, and why the incremental publisher could keep minute
-- totals current while user concurrency silently inflated (measured once as
-- served 2,953 vs true 2,844 — ADR 0012). With ReplacingMergeTree(computed_at)
-- the newest full re-derivation of a bucket WINS outright, shrink included.
-- Verified on Cloud 26.2.1.525 before this file was rewritten: an
-- AggregateFunction(uniqExact, String) payload column is accepted by
-- ReplacingMergeTree, FINAL keeps only the newest version per key, and a
-- bucket re-inserted with fewer members reads back with fewer members.
--
-- THE MV IS RETIRED, NOT MOVED. An incremental MV sees one inserted BLOCK and
-- would write a PARTIAL state (that block's sessions only) at a fresh
-- computed_at — under replace semantics the newest write wins, so a partial
-- state would silently ERASE the complete bucket it lands on. Population is
-- therefore owned by exactly two callers of the INSERT below: the publisher
-- (scoped) and the rebuild (whole, after TRUNCATE). Nothing else may write
-- this table.
--
-- MIGRATION of a pre-ADR-0016 database: the engine cannot be ALTERed.
-- tools/build-model.sh detects the old engine, DROPs the table and the MV, and
-- re-applies this file — safe because every byte here is derived state,
-- rebuilt from session_intervals in seconds.
-- ============================================================================

-- Retired by ADR 0016 — see "THE MV IS RETIRED" above. No-op on a fresh
-- database; on an existing one this is the write path being closed.
DROP VIEW IF EXISTS mv_user_minute;

-- ---------------------------------------------------------------------------
-- The serving table. One uniqExact state per (dims, minute) bucket, versioned
-- by computed_at so the newest derivation of a bucket replaces the old one.
--
-- ORDER BY (platform, country, content_id, minute): identical reasoning to
-- cc_minute_delta / cc_minute_stateless — dashboards filter on the dims first,
-- then range-scan minute; a coarse dim prefix prunes because it repeats.
-- PARTITION BY day so a day's worth of buckets lands and merges together,
-- matching every other table in this model. The sort key is also the REPLACE
-- key: FINAL collapses versions per bucket, never across buckets.
--
-- computed_at DEFAULT now64(3): every caller of the INSERT below stamps the
-- write time implicitly — the same versioning idiom as cc_hour_agg, and the
-- only ordering that is correct when a correction SHRINKS a bucket (max-style
-- versions would keep the stale, larger set).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cc_user_minute
(
    minute       DateTime,
    platform     LowCardinality(String),
    country      LowCardinality(String),
    content_id   Int64,
    active_state AggregateFunction(uniqExact, String),
    computed_at  DateTime64(3) DEFAULT now64(3)
)
ENGINE = ReplacingMergeTree(computed_at)
PARTITION BY toYYYYMMDD(minute)
ORDER BY (platform, country, content_id, minute)
SETTINGS min_bytes_for_wide_part = 0;

-- ---------------------------------------------------------------------------
-- THE CANONICAL RE-DERIVATION. Recomputes every (minute, dims) bucket it can
-- see, from session_intervals FINAL — the same expansion shape as
-- v_concurrency_minute_intervals in 20_views.sql (row-level arrayJoin, no
-- cross-block state).
--
-- Two branches, one job each:
--   * "new coverage"     — who is actually active in each bucket now. These
--                          rows carry covered = 1 and contribute their user_id.
--   * "existing buckets" — every bucket key already present in the table.
--                          These rows carry covered = 0 and contribute NOTHING
--                          to the state; they exist so a bucket whose coverage
--                          VANISHED still gets a row — an EMPTY state at a
--                          newer computed_at, which is the retraction. Without
--                          this branch a stale bucket would survive FINAL for
--                          ever (the exact defect class the prune phase in
--                          tools/publish.sh exists for).
--
-- uniqExactStateIf(user_id, covered = 1) over zero qualifying rows is a valid
-- EMPTY state that merges as identity and reads back as 0 — verified on Cloud
-- 26.2.1.525 before shipping (as was the -If state's assignability to the
-- plain uniqExact column).
--
-- Unscoped (as run by tools/build-model.sh after TRUNCATE, and by this file's
-- first apply) it is a full backfill: branch 2 reads an empty or superseded
-- table and every bucket is recomputed. tools/publish.sh templates the three
-- anchor lines marked below to narrow both branches to one batch's touched
-- minutes — over-covering a minute is idempotent (same input -> same state at
-- a newer version), so the scope must be a SUPERSET of the touched minutes,
-- never exact to the row.
--
-- Anchor lines (sed-templated by tools/publish.sh; template_or_die asserts the
-- injected markers, so a drifted anchor is a hard stop, not a silent full
-- recompute):
--   'FROM session_intervals FINAL'          -> event-window prefilter
--   'WHERE 1 /* publish: new coverage */'   -> minute scope, branch 1
--   'WHERE 1 /* publish: existing buckets */' -> minute scope, branch 2
--
-- PUBLISH_EXTRACT_BEGIN:user — tools/publish.sh and tools/publish-test.sh cut
-- the single statement between these two markers to run it over HTTP. Keep the
-- markers immediately around ONE statement.
INSERT INTO cc_user_minute (minute, platform, country, content_id, active_state)
SELECT
    minute,
    platform,
    country,
    content_id,
    uniqExactStateIf(user_id, covered = 1) AS active_state
FROM
(
    SELECT
        toDateTime(m) AS minute,
        platform,
        country,
        content_id,
        user_id,
        1 AS covered
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
    WHERE 1 /* publish: new coverage */

    UNION ALL

    SELECT
        minute,
        platform,
        country,
        content_id,
        '' AS user_id,
        0 AS covered
    FROM cc_user_minute FINAL
    WHERE 1 /* publish: existing buckets */
)
GROUP BY minute, platform, country, content_id;
-- PUBLISH_EXTRACT_END:user

-- ---------------------------------------------------------------------------
-- Serving views — merge state to a plain number, once, here (same rationale
-- as 20_views.sql: a chart tool cannot read an AggregateFunction column).
--
-- Both read FINAL: ReplacingMergeTree collapses versions in the background, so
-- before a merge a re-derived bucket has both the old and the new row, and
-- without FINAL uniqExactMerge would union them — re-importing the exact
-- defect this engine change removes. FINAL is cheap at this tier's size
-- (~92K rows).
--
-- Both drop zero-user buckets: an empty state is a retraction tombstone (see
-- the INSERT above), and "no active users" serves as no row — the same answer
-- a from-scratch rebuild gives.
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
FROM cc_user_minute FINAL
GROUP BY minute, platform, country, content_id
HAVING concurrent_users > 0;

-- The headline user curve: total distinct users active per minute, all
-- dimensions collapsed. Re-merges the underlying states rather than summing
-- the per-dimension view above — uniqExactMerge across ALL states for a
-- minute deduplicates a user active on several dims/sessions at once; SUM()
-- would not, and would reproduce exactly the over-count this file exists to
-- avoid. Empty tombstone states union in as the identity, so they cannot
-- inflate the count; the HAVING drops minutes where nothing is left at all.
CREATE OR REPLACE VIEW v_user_concurrency_minute_total AS
SELECT
    minute,
    uniqExactMerge(active_state) AS concurrent_users
FROM cc_user_minute FINAL
GROUP BY minute
HAVING concurrent_users > 0;
