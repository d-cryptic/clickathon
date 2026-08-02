-- ============================================================================
-- 10_intervals.sql — durable tables for the foreground-only serving model.
--
-- `queries/materialize_intervals.sql` performs the cross-block sessionization.
-- It intentionally is not an incremental MV: an MV sees only its insert block
-- and cannot safely reconstruct a session spanning blocks or late arrivals.
-- ============================================================================

CREATE TABLE IF NOT EXISTS session_intervals
(
    video_session_id String,
    user_id          String,
    content_id       Int64,
    platform         LowCardinality(String),
    country          LowCardinality(String),
    app_version      LowCardinality(String),
    audio_language   LowCardinality(String),
    subtitle_language LowCardinality(String),
    player_version   LowCardinality(String),
    interval_start   DateTime64(3),
    interval_end     DateTime64(3),
    is_open          UInt8,
    build_version    UInt64
)
ENGINE = ReplacingMergeTree(build_version)
ORDER BY (video_session_id, interval_start)
SETTINGS min_bytes_for_wide_part = 0;

-- One signed boundary per active interval per hour.  An hour-local running sum
-- is an absolute concurrency value, so range queries never need a historical
-- carry-in scan.  `delta` remains additive, making late corrections appendable.
CREATE TABLE IF NOT EXISTS cc_minute_delta
(
    minute      DateTime,
    platform    LowCardinality(String),
    country     LowCardinality(String),
    content_id  Int64,
    subtitle_language LowCardinality(String),
    player_version    LowCardinality(String),
    audio_language    LowCardinality(String),
    app_version       LowCardinality(String),
    delta       SimpleAggregateFunction(sum, Int64),
    starts      SimpleAggregateFunction(sum, Int64),
    ends        SimpleAggregateFunction(sum, Int64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMMDD(minute)
ORDER BY (platform, country, content_id, minute,
          subtitle_language, player_version, audio_language, app_version)
SETTINGS
    min_bytes_for_wide_part = 0,
    -- A finalizer retry must not append a second copy of an identical run.
    -- This is a bounded transport aid, not the correctness boundary; published
    -- correction snapshots below remain invisible until their run is committed.
    non_replicated_deduplication_window = 1000;

-- Bootstrap snapshot of each session's hour-clipped boundary markers.
-- `cc_minute_delta` is the fast baseline; this table is only point-read by the
-- finalizer to calculate a late/session correction exactly.
CREATE TABLE IF NOT EXISTS session_delta_base
(
    video_session_id String,
    platform         LowCardinality(String),
    country          LowCardinality(String),
    content_id       Int64,
    app_version      LowCardinality(String),
    audio_language   LowCardinality(String),
    subtitle_language LowCardinality(String),
    player_version   LowCardinality(String),
    minute           DateTime,
    delta            Int64
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(minute)
ORDER BY (video_session_id, platform, country, content_id,
          app_version, audio_language, subtitle_language, player_version, minute)
SETTINGS
    min_bytes_for_wide_part = 0,
    non_replicated_deduplication_window = 1000;

-- Immutable phase log. A correction run is query-visible only when its greatest
-- ordered phase is `published`; a crash in prepare/stage leaves no partial correction
-- in the dashboard. `run_sequence` establishes the deterministic latest state
-- for a session marker without depending on asynchronous part merges.
CREATE TABLE IF NOT EXISTS finalizer_run_log
(
    run_id                UUID,
    run_sequence          UInt64,
    phase                 Enum8('prepared' = 1, 'staged' = 2, 'published' = 3, 'aborted' = 4),
    source_from           DateTime64(3),
    source_high_watermark DateTime64(3),
    event_watermark       DateTime64(3),
    affected_sessions     UInt64,
    staged_rows           UInt64,
    model_version         LowCardinality(String),
    recorded_at           DateTime64(3)
)
ENGINE = MergeTree
ORDER BY (run_id, recorded_at)
SETTINGS
    min_bytes_for_wide_part = 0,
    non_replicated_deduplication_window = 1000;

-- A row is the current correction (new marker minus bootstrap marker) for one
-- session/dimension/minute. Zero rows are deliberate tombstones. The serving
-- query reads argMax(delta, run_sequence) only from published runs, so a retry
-- or a staged-but-unpublished batch cannot double-count.
CREATE TABLE IF NOT EXISTS session_delta_correction_stage
(
    run_id             UUID,
    run_sequence       UInt64,
    video_session_id   String,
    platform           LowCardinality(String),
    country            LowCardinality(String),
    content_id         Int64,
    app_version        LowCardinality(String),
    audio_language     LowCardinality(String),
    subtitle_language  LowCardinality(String),
    player_version     LowCardinality(String),
    minute             DateTime,
    correction_delta   Int64
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(minute)
ORDER BY (video_session_id, platform, country, content_id,
          app_version, audio_language, subtitle_language, player_version, minute, run_sequence)
SETTINGS
    min_bytes_for_wide_part = 0,
    non_replicated_deduplication_window = 1000;

-- Versioned, bounded, exact minute snapshots for the newest event-time window.
-- A snapshot is only used when it was built from the selected correction run;
-- otherwise serving falls back to the correction overlay.  This prevents a
-- stale hot tier from hiding a newly published late-event correction.
CREATE TABLE IF NOT EXISTS exact_tail_run_log
(
    run_id                    UUID,
    run_sequence              UInt64,
    finalizer_run_sequence    UInt64,
    phase                     Enum8('prepared' = 1, 'staged' = 2, 'published' = 3, 'aborted' = 4),
    event_watermark           DateTime,
    tail_until                DateTime,
    source_high_watermark     DateTime64(3),
    staged_rows               UInt64,
    model_version             LowCardinality(String),
    recorded_at               DateTime64(3)
)
ENGINE = MergeTree
ORDER BY (run_id, recorded_at)
SETTINGS
    min_bytes_for_wide_part = 0,
    non_replicated_deduplication_window = 1000;

-- One full, publication-gated snapshot over a deliberately short window.
-- Rows with zero concurrency are omitted: absence inside the selected snapshot
-- means zero, while a run with no published matching correction is not used.
CREATE TABLE IF NOT EXISTS exact_tail_minute_stage
(
    run_id        UUID,
    platform      LowCardinality(String),
    country       LowCardinality(String),
    content_id    Int64,
    app_version   LowCardinality(String),
    audio_language LowCardinality(String),
    subtitle_language LowCardinality(String),
    player_version LowCardinality(String),
    minute        DateTime,
    concurrency   UInt64
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(minute)
ORDER BY (run_id, platform, country, content_id,
          app_version, audio_language, subtitle_language, player_version, minute)
SETTINGS
    min_bytes_for_wide_part = 0,
    non_replicated_deduplication_window = 1000;

-- A compact change-point serving view. Consumers generate the requested minute
-- grid and forward-fill within each hour; this avoids permanently exploding all
-- historical intervals into per-minute rows.
CREATE OR REPLACE VIEW v_concurrency_change AS
WITH
    published_runs AS
    (
        SELECT run_id
        FROM finalizer_run_log
        GROUP BY run_id
        HAVING max(phase) = 'published'
    ),
    correction_state AS
    (
        SELECT
            platform,
            country,
            content_id,
            minute,
            argMax(correction_delta, run_sequence) AS delta
        FROM session_delta_correction_stage
        WHERE run_id IN published_runs
        GROUP BY
            video_session_id, platform, country, content_id,
            app_version, audio_language, subtitle_language, player_version, minute
    )
SELECT
    minute,
    platform,
    country,
    content_id,
    sum(sum(delta)) OVER
    (
        PARTITION BY platform, country, content_id, toStartOfHour(minute)
        ORDER BY minute
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS concurrency
FROM
(
    SELECT minute, platform, country, content_id, delta
    FROM cc_minute_delta

    UNION ALL

    SELECT minute, platform, country, content_id, delta
    FROM correction_state
)
GROUP BY minute, platform, country, content_id;
