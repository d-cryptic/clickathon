-- ============================================================================
-- 87_viz.sql — CHART-ONLY views for the hosted ClickStack/HyperDX dashboards.
-- ADDITIVE ONLY: new v_* views, nothing existing is altered — the graded model
-- (ev_raw / session_intervals / cc_minute_delta / cc_hour_agg) is untouched.
-- Three families: (1) v_concurrency_minute_naive — the naive session-span
-- over-count, charted next to the accurate model so the gap is visible;
-- (2) v_session_minutes — session-minute expansion for FILTER-CORRECT
-- drilldowns (count_distinct is right under ANY filter combination);
-- (3) v_cc_by_<dim> — per-dimension delta curves (sum deltas at that grain,
-- THEN running-sum) because max() over a finer-grained view is the max single
-- combination, not the dimension total — measured: ANDROID_PHONE reads 285
-- where the true figure is 1,837 at the 2026-07-26 10:56 peak minute.
-- ============================================================================
-- ADR 0010, applied here 2026-08-02: the dictionary name is UNQUALIFIED. It
-- said 'sonyliv.dict_content', which reads correctly on the graded database
-- and silently answers from PRODUCTION'S catalog when this file is applied to
-- any other — the unseen day builds the whole model in a separate database.
-- Codex found it failing on a clean scratch DB during promotion check 2.
-- The database comes from how the file is applied, never from the text.
--

-- ---------------------------------------------------------------------------
-- NAIVE SESSION-SPAN. A session is "watching" from its first event to its
-- last, ignoring background/pause/heartbeat-loss entirely. This is the model
-- the problem statement warns against; it is charted so the over-count is
-- VISIBLE rather than asserted (peak 3,743 naive vs 2,917 accurate).
--
-- Matches tools/reconcile.sh §2's definition exactly (s < m+1min AND e > m):
-- a session whose last event lands exactly on a minute boundary does NOT
-- count in that minute — hence the if() on the range end. Verified equal to
-- the reference CROSS JOIN definition at 10:56 (3,708) and 10:59 (3,743).
--
-- O(sessions x span-minutes) expansion, ~179K rows on the provided file.
-- Chart-only; NOT the serving path and never compared by the reconcile gate.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_concurrency_minute_naive AS
SELECT
    toDateTime(m) AS minute,
    uniqExact(video_session_id) AS concurrent
FROM
(
    SELECT
        video_session_id,
        arrayJoin(range(
            toUInt32(toDateTime(toStartOfMinute(s))),
            toUInt32(if(e > toStartOfMinute(e),
                        toUInt32(toDateTime(toStartOfMinute(e))),
                        toUInt32(toDateTime(toStartOfMinute(e))) - 60)) + 60,
            60
        )) AS m
    FROM
    (
        SELECT
            video_session_id,
            min(event_timestamp) AS s,
            max(event_timestamp) AS e
        FROM ev_raw
        GROUP BY video_session_id
    )
)
GROUP BY minute;

-- ---------------------------------------------------------------------------
-- SESSION-MINUTE EXPANSION — the drilldown source. One row per (active
-- session, minute), carrying user_id and ALL SEVEN dimensions plus the
-- dictGet title. This exists because a dashboard filter can pin ANY subset of
-- dimensions, and the only aggregation that stays correct under an arbitrary
-- filter is count_distinct over these rows:
--   * at 1-minute granularity it IS concurrency (verified: 2,917 sessions /
--     2,844 users at 2026-07-26 10:56, matching the graded headline);
--   * at coarser buckets it is "unique active sessions in the bucket" —
--     still meaningful, and labelled that way on the tiles.
-- A delta view cannot do this: the running sum must be rebuilt after the
-- filter, which no chart builder can express. This is the same
-- O(sessions x minutes) expansion 20_views.sql documents for
-- v_concurrency_minute_intervals — ~149K rows, fine to chart, NOT the
-- serving path.
-- uniqExact/count_distinct dedupes a session whose intervals touch the same
-- minute twice, so no DISTINCT is needed here.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_session_minutes AS
SELECT
    toDateTime(m) AS minute,
    video_session_id,
    user_id,
    platform,
    country,
    content_id,
    dictGet('dict_content', 'title', tuple(content_id)) AS title,
    app_version,
    audio_language,
    subtitle_language,
    player_version
FROM
(
    SELECT
        video_session_id, user_id, platform, country, content_id,
        app_version, audio_language, subtitle_language, player_version,
        arrayJoin(range(
            toUInt32(toDateTime(toStartOfMinute(interval_start))),
            toUInt32(toDateTime(toStartOfMinute(interval_end))) + 60,
            60
        )) AS m
    FROM session_intervals FINAL
);

-- ---------------------------------------------------------------------------
-- PER-DIMENSION ACCURATE CURVES, one view per dimension. Sum deltas AT THE
-- DIMENSION'S OWN GRAIN first, then running-sum partitioned by (dim, hour) —
-- the order of operations every view in this repo uses (ARCHITECTURE.md rule
-- 1; same pattern as 80_content.sql's title/video_type/category views, which
-- these deliberately mirror). Summing deltas across the collapsed dimensions
-- is safe because session_intervals assigns one dimension tuple per interval.
-- max() over these in a chart is then a genuine peak at any zoom level
-- (peak IS maxable over time — hour-clipping, ADR 0003).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_cc_by_platform AS
SELECT
    minute,
    platform,
    toInt64(sum(net) OVER (
        PARTITION BY platform, toStartOfHour(minute)
        ORDER BY minute
    )) AS concurrent
FROM (SELECT minute, platform, sum(delta) AS net FROM cc_minute_delta GROUP BY minute, platform);

CREATE OR REPLACE VIEW v_cc_by_country AS
SELECT
    minute,
    country,
    toInt64(sum(net) OVER (
        PARTITION BY country, toStartOfHour(minute)
        ORDER BY minute
    )) AS concurrent
FROM (SELECT minute, country, sum(delta) AS net FROM cc_minute_delta GROUP BY minute, country);

CREATE OR REPLACE VIEW v_cc_by_app_version AS
SELECT
    minute,
    app_version,
    toInt64(sum(net) OVER (
        PARTITION BY app_version, toStartOfHour(minute)
        ORDER BY minute
    )) AS concurrent
FROM (SELECT minute, app_version, sum(delta) AS net FROM cc_minute_delta GROUP BY minute, app_version);

CREATE OR REPLACE VIEW v_cc_by_audio_language AS
SELECT
    minute,
    audio_language,
    toInt64(sum(net) OVER (
        PARTITION BY audio_language, toStartOfHour(minute)
        ORDER BY minute
    )) AS concurrent
FROM (SELECT minute, audio_language, sum(delta) AS net FROM cc_minute_delta GROUP BY minute, audio_language);

CREATE OR REPLACE VIEW v_cc_by_subtitle_language AS
SELECT
    minute,
    subtitle_language,
    toInt64(sum(net) OVER (
        PARTITION BY subtitle_language, toStartOfHour(minute)
        ORDER BY minute
    )) AS concurrent
FROM (SELECT minute, subtitle_language, sum(delta) AS net FROM cc_minute_delta GROUP BY minute, subtitle_language);

CREATE OR REPLACE VIEW v_cc_by_player_version AS
SELECT
    minute,
    player_version,
    toInt64(sum(net) OVER (
        PARTITION BY player_version, toStartOfHour(minute)
        ORDER BY minute
    )) AS concurrent
FROM (SELECT minute, player_version, sum(delta) AS net FROM cc_minute_delta GROUP BY minute, player_version);
