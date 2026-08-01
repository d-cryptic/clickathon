-- Build the per-session marker snapshot matching cc_minute_delta exactly.
-- Run only through tools/bootstrap-finalizer.sh after historical materialization.

INSERT INTO session_delta_base
WITH clipped AS
(
    SELECT
        video_session_id,
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
)
SELECT
    video_session_id,
    platform,
    country,
    content_id,
    minute,
    sum(delta) AS delta
FROM boundaries
GROUP BY video_session_id, platform, country, content_id, minute
HAVING delta != 0;
