-- ============================================================================
-- Stateful, event-time sessionization followed by hour-clipped delta emission.
--
-- Tunables live here only. Intervals are half-open [start, end); a partial final
-- minute counts as active, so a close is emitted in the following minute unless
-- that minute belongs to the next hour (which re-opens independently).
-- ============================================================================

INSERT INTO session_intervals
WITH
    150 AS heartbeat_gap_s,
    60 AS tail_grace_s,
    toDateTime64(0, 3) AS epoch,
    -- There is no source event id. Exact payload duplicates are therefore treated
    -- as retry copies; the raw table remains unchanged for audit/replay.
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
            lagInFrame(event_timestamp, 1, epoch) OVER
            (
                PARTITION BY video_session_id, stop_epoch
                ORDER BY event_order
                ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
            ) AS previous_signal_at
            , lagInFrame(platform, 1, '') OVER
            (
                PARTITION BY video_session_id, stop_epoch
                ORDER BY event_order
                ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
            ) AS previous_platform
            , lagInFrame(country, 1, '') OVER
            (
                PARTITION BY video_session_id, stop_epoch
                ORDER BY event_order
                ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
            ) AS previous_country
            , lagInFrame(content_id, 1, toInt64(0)) OVER
            (
                PARTITION BY video_session_id, stop_epoch
                ORDER BY event_order
                ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
            ) AS previous_content_id
            , leadInFrame(event_timestamp, 1, epoch) OVER
            (
                PARTITION BY video_session_id, stop_epoch
                ORDER BY event_order
                ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
            ) AS next_signal_at
            , leadInFrame(platform, 1, '') OVER
            (
                PARTITION BY video_session_id, stop_epoch
                ORDER BY event_order
                ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
            ) AS next_platform
            , leadInFrame(country, 1, '') OVER
            (
                PARTITION BY video_session_id, stop_epoch
                ORDER BY event_order
                ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
            ) AS next_country
            , leadInFrame(content_id, 1, toInt64(0)) OVER
            (
                PARTITION BY video_session_id, stop_epoch
                ORDER BY event_order
                ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
            ) AS next_content_id
        FROM stateful
        WHERE
            event_type = 'VideoHeartbeat'
            AND event != 'pause'
            AND last_background <= last_foreground
            AND last_pause <= last_resume
            AND last_terminal = 0
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
            )
                OVER
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
            any(user_id) AS interval_user_id,
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
            ) AS next_dimension_change_at,
            max(session_ended) AS session_ended
        FROM grouped
        GROUP BY video_session_id, stop_epoch, interval_number
    )
SELECT
    video_session_id,
    interval_user_id AS user_id,
    interval_content_id AS content_id,
    interval_platform AS platform,
    interval_country AS country,
    interval_start,
    least(
        last_signal_at + toIntervalSecond(tail_grace_s),
        if(first_stop_at = epoch, last_signal_at + toIntervalSecond(tail_grace_s), first_stop_at),
        if(next_dimension_change_at = epoch, last_signal_at + toIntervalSecond(tail_grace_s), next_dimension_change_at)
    ) AS interval_end,
    1 - session_ended AS is_open,
    now64(3) AS generated_at
FROM intervals
WHERE interval_start < interval_end;

INSERT INTO cc_minute_delta
WITH clipped AS
(
    SELECT
        platform,
        country,
        content_id,
        interval_start,
        interval_end,
        toStartOfHour(interval_start) + toIntervalHour(hour_offset) AS hour
    FROM session_intervals
    ARRAY JOIN range(dateDiff('hour', toStartOfHour(interval_start), toStartOfHour(interval_end)) + 1) AS hour_offset
    WHERE interval_start < interval_end
), boundaries AS
(
    SELECT
        toStartOfMinute(greatest(interval_start, hour)) AS minute,
        platform,
        country,
        content_id,
        toInt64(1) AS delta,
        toUInt64(1) AS starts,
        toUInt64(0) AS ends
    FROM clipped
    WHERE interval_start < hour + toIntervalHour(1) AND interval_end > hour

    UNION ALL

    SELECT
        -- Intervals are half-open.  A stop exactly at 10:05:00 must not
        -- contribute to minute 10:05; a stop at 10:05:00.001 still does.
        if(
            interval_end = toStartOfMinute(interval_end),
            toStartOfMinute(interval_end),
            toStartOfMinute(interval_end) + toIntervalMinute(1)
        ) AS minute,
        platform,
        country,
        content_id,
        toInt64(-1) AS delta,
        toUInt64(0) AS starts,
        toUInt64(1) AS ends
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
)
SELECT minute, platform, country, content_id, sum(delta), sum(starts), sum(ends)
FROM boundaries
GROUP BY minute, platform, country, content_id;
