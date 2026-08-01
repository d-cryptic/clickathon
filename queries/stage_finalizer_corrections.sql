-- Re-derive only sessions whose raw ingestion time is in [source_from, source_hwm].
-- The result is a complete target correction per touched session marker, not an
-- incremental delta. It remains invisible until tools/finalize.sh publishes run_id.

INSERT INTO session_delta_correction_stage
WITH
    150 AS heartbeat_gap_s,
    60 AS tail_grace_s,
    toDateTime64(0, 3) AS epoch,
    changed_sessions AS
    (
        SELECT DISTINCT video_session_id
        FROM ev_raw
        WHERE
            ingested_at >= {source_from:DateTime64(3)}
            AND ingested_at <= {source_high_watermark:DateTime64(3)}
    ),
    source_events AS
    (
        SELECT DISTINCT
            content_id,
            video_session_id,
            user_id,
            event_type,
            event,
            event_timestamp,
            platform,
            app_version,
            country,
            audio_language,
            subtitle_language,
            player_version,
            session_start_epoch
        FROM ev_raw
        WHERE
            video_session_id IN changed_sessions
            AND ingested_at <= {source_high_watermark:DateTime64(3)}
    ),
    events AS
    (
        SELECT
            *,
            toUnixTimestamp64Milli(event_timestamp) * 10
              + multiIf(
                    event_type IN ('AppBackgrounded', 'VideoSessionEnd') OR event = 'pause', 1,
                    event_type IN ('AppForegrounded', 'VideoPlay') OR event = 'resume', 2,
                    5
                ) AS event_order,
            event_type = 'AppBackgrounded' AS is_backgrounded,
            event_type = 'AppForegrounded' AS is_foregrounded,
            event = 'pause' AS is_paused,
            event IN ('resume', 'Play') AS is_resumed,
            event_type = 'VideoSessionEnd' AS is_terminal,
            event_type IN ('AppBackgrounded', 'VideoSessionEnd') OR event = 'pause' AS is_stop
        FROM source_events
    ),
    stateful AS
    (
        SELECT
            *,
            maxIf(event_order, is_backgrounded) OVER session_window AS last_background,
            maxIf(event_order, is_foregrounded) OVER session_window AS last_foreground,
            maxIf(event_order, is_paused) OVER session_window AS last_pause,
            maxIf(event_order, is_resumed) OVER session_window AS last_resume,
            maxIf(event_order, is_terminal) OVER session_window AS last_terminal,
            sum(is_stop) OVER session_window AS stop_epoch,
            minIf(event_timestamp, is_stop) OVER following_window AS next_stop_at,
            max(is_terminal) OVER full_session_window AS session_ended
        FROM events
        WINDOW
            session_window AS
                (PARTITION BY video_session_id ORDER BY event_order ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
            following_window AS
                (PARTITION BY video_session_id ORDER BY event_order ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING),
            full_session_window AS
                (PARTITION BY video_session_id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
    ),
    signals AS
    (
        SELECT
            *,
            lagInFrame(event_timestamp, 1, epoch) OVER signal_window AS previous_signal_at,
            lagInFrame(platform, 1, '') OVER signal_window AS previous_platform,
            lagInFrame(country, 1, '') OVER signal_window AS previous_country,
            lagInFrame(content_id, 1, toInt64(0)) OVER signal_window AS previous_content_id,
            leadInFrame(event_timestamp, 1, epoch) OVER signal_window AS next_signal_at,
            leadInFrame(platform, 1, '') OVER signal_window AS next_platform,
            leadInFrame(country, 1, '') OVER signal_window AS next_country,
            leadInFrame(content_id, 1, toInt64(0)) OVER signal_window AS next_content_id
        FROM stateful
        WHERE
            event_type = 'VideoHeartbeat'
            AND event != 'pause'
            AND last_background <= last_foreground
            AND last_pause <= last_resume
            AND last_terminal = 0
        WINDOW signal_window AS
            (PARTITION BY video_session_id, stop_epoch ORDER BY event_order ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
    ),
    grouped AS
    (
        SELECT
            *,
            sum(
                previous_signal_at = epoch
                OR dateDiff('second', previous_signal_at, event_timestamp) > heartbeat_gap_s
                OR platform != previous_platform
                OR country != previous_country
                OR content_id != previous_content_id
            ) OVER
            (
                PARTITION BY video_session_id, stop_epoch
                ORDER BY event_order
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS interval_number
        FROM signals
    ),
    intervals AS
    (
        SELECT
            video_session_id,
            any(content_id) AS interval_content_id,
            any(platform) AS interval_platform,
            any(country) AS interval_country,
            min(event_timestamp) AS interval_start,
            max(event_timestamp) AS last_signal_at,
            minIf(next_stop_at, next_stop_at != epoch) AS first_stop_at,
            minIf(
                next_signal_at,
                next_signal_at != epoch
                AND (platform != next_platform OR country != next_country OR content_id != next_content_id)
            ) AS next_dimension_change_at
        FROM grouped
        GROUP BY video_session_id, stop_epoch, interval_number
    ),
    bounded_intervals AS
    (
        SELECT
            video_session_id,
            interval_platform AS platform,
            interval_country AS country,
            interval_content_id AS content_id,
            interval_start,
            least(
                last_signal_at + toIntervalSecond(tail_grace_s),
                if(first_stop_at = epoch, last_signal_at + toIntervalSecond(tail_grace_s), first_stop_at),
                if(next_dimension_change_at = epoch, last_signal_at + toIntervalSecond(tail_grace_s), next_dimension_change_at)
            ) AS interval_end
        FROM intervals
        WHERE interval_start < interval_end
    ),
    clipped AS
    (
        SELECT
            video_session_id,
            platform,
            country,
            content_id,
            interval_start,
            interval_end,
            toStartOfHour(interval_start) + toIntervalHour(hour_offset) AS hour
        FROM bounded_intervals
        ARRAY JOIN range(dateDiff('hour', toStartOfHour(interval_start), toStartOfHour(interval_end)) + 1) AS hour_offset
    ),
    new_boundaries AS
    (
        SELECT
            video_session_id,
            platform,
            country,
            content_id,
            toStartOfMinute(greatest(interval_start, hour)) AS minute,
            toInt64(1) AS delta
        FROM clipped
        WHERE interval_start < hour + toIntervalHour(1) AND interval_end > hour

        UNION ALL

        SELECT
            video_session_id,
            platform,
            country,
            content_id,
            if(
                interval_end = toStartOfMinute(interval_end),
                toStartOfMinute(interval_end),
                toStartOfMinute(interval_end) + toIntervalMinute(1)
            ) AS minute,
            toInt64(-1) AS delta
        FROM clipped
        WHERE
            interval_start < hour + toIntervalHour(1)
            AND interval_end > hour
            AND interval_end < hour + toIntervalHour(1)
            AND if(
                interval_end = toStartOfMinute(interval_end),
                toStartOfMinute(interval_end),
                toStartOfMinute(interval_end) + toIntervalMinute(1)
            ) < hour + toIntervalHour(1)
    ),
    new_markers AS
    (
        SELECT video_session_id, platform, country, content_id, minute, sum(delta) AS delta
        FROM new_boundaries
        GROUP BY video_session_id, platform, country, content_id, minute
        HAVING delta != 0
    ),
    published_runs AS
    (
        SELECT run_id
        FROM finalizer_run_log
        GROUP BY run_id
        HAVING max(phase) = 'published'
    ),
    previous_corrections AS
    (
        SELECT
            video_session_id,
            platform,
            country,
            content_id,
            minute,
            argMax(correction_delta, run_sequence) AS delta
        FROM session_delta_correction_stage
        WHERE
            video_session_id IN changed_sessions
            AND run_id IN published_runs
        GROUP BY video_session_id, platform, country, content_id, minute
    ),
    candidates AS
    (
        SELECT
            video_session_id,
            platform,
            country,
            content_id,
            minute,
            sum(new_delta) - sum(base_delta) AS target_delta,
            sum(previous_delta) AS previous_delta
        FROM
        (
            SELECT video_session_id, platform, country, content_id, minute, delta AS new_delta, toInt64(0) AS base_delta, toInt64(0) AS previous_delta FROM new_markers
            UNION ALL
            SELECT video_session_id, platform, country, content_id, minute, toInt64(0), delta, toInt64(0) FROM session_delta_base WHERE video_session_id IN changed_sessions
            UNION ALL
            SELECT video_session_id, platform, country, content_id, minute, toInt64(0), toInt64(0), delta FROM previous_corrections
        )
        GROUP BY video_session_id, platform, country, content_id, minute
    )
SELECT
    {run_id:UUID} AS run_id,
    {run_sequence:UInt64} AS run_sequence,
    video_session_id,
    platform,
    country,
    content_id,
    minute,
    target_delta AS correction_delta
FROM candidates
WHERE target_delta != previous_delta;
