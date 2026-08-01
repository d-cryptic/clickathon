-- ============================================================================
-- 00_schema.sql — raw landing + content dimension
-- Runs on FIRST BOOT ONLY (empty data dir). Iterating means `docker compose down -v`.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Raw events, exactly as delivered. One row per event.
--
-- ORDER BY (toStartOfHour(event_timestamp), platform, video_session_id, event_timestamp)
-- Low cardinality first, per the official rule `schema-pk-cardinality-order` (CRITICAL).
-- An earlier version led with video_session_id for session locality; MEASURED on the real
-- file, that was 17.3x worse on the dashboard shape and bought nothing, because a full
-- interval rebuild GROUP BYs every row regardless. See docs/adr/0002.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ev_raw
(
    content_id          Int64,
    video_session_id    String,
    user_id             String,
    event_type          LowCardinality(String),
    event               LowCardinality(String),
    event_timestamp     DateTime64(3),          -- source is epoch MILLIS
    platform            LowCardinality(String),
    app_version         LowCardinality(String),
    country             LowCardinality(String),
    audio_language      LowCardinality(String),
    subtitle_language   LowCardinality(String),
    player_version      LowCardinality(String),
    session_start_epoch DateTime64(3),

    -- skip indexes: the two lookups that are not the sort key prefix
    INDEX idx_content content_id TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_ts      event_timestamp TYPE minmax GRANULARITY 1
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(event_timestamp)
ORDER BY (toStartOfHour(event_timestamp), platform, video_session_id, event_timestamp)
SETTINGS index_granularity = 8192,
         -- per-column compression stats read 0 for COMPACT parts; force Wide so the
         -- evidence harness reports real numbers even on a small load. See docs/VERIFIED.md.
         min_bytes_for_wide_part = 0,
         -- non-replicated MergeTree has insert dedup OFF by default (window = 0).
         -- Turn it on so a replayed batch is idempotent — the unseen day may be re-loaded.
         non_replicated_deduplication_window = 1000;

-- ---------------------------------------------------------------------------
-- Content dimension. Small and static -> also exposed as a DICTIONARY (20_dicts.sql)
-- because dictGet measured 34x faster than a JOIN on 5M rows.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS content_dim
(
    content_id Int64,
    title      String,
    video_type LowCardinality(String),
    category   LowCardinality(String)
)
ENGINE = ReplacingMergeTree
ORDER BY content_id;
