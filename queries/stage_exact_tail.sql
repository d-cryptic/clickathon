-- Materialize one exact, bounded minute snapshot from the same hour-clipped
-- state-machine markers used by serving.  It deliberately runs after a
-- published finalizer run, so late-event corrections are already included.

INSERT INTO exact_tail_minute_stage
WITH
    toDateTime({event_watermark:String}, 'UTC') AS watermark,
    toDateTime({tail_until:String}, 'UTC') AS tail_until,
    toStartOfHour(watermark) AS first_hour,
    published_runs AS
    (
        SELECT run_id
        FROM finalizer_run_log
        GROUP BY run_id
        HAVING
            max(phase) = 'published'
            AND max(run_sequence) <= {finalizer_run_sequence:UInt64}
    ),
    correction_state AS
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
            minute >= first_hour
            AND minute <= tail_until
            AND run_id IN published_runs
        GROUP BY video_session_id, platform, country, content_id, minute
    ),
    deltas AS
    (
        SELECT
            minute,
            platform,
            country,
            content_id,
            sum(delta) AS delta
        FROM
        (
            SELECT minute, platform, country, content_id, delta
            FROM cc_minute_delta
            WHERE minute >= first_hour AND minute <= tail_until

            UNION ALL

            SELECT minute, platform, country, content_id, delta
            FROM correction_state
        )
        GROUP BY minute, platform, country, content_id
    ),
    changes AS
    (
        SELECT
            minute,
            platform,
            country,
            content_id,
            toStartOfHour(minute) AS hour,
            sum(delta) OVER
            (
                PARTITION BY platform, country, content_id, toStartOfHour(minute)
                ORDER BY minute
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS concurrency
        FROM deltas
    ),
    dimension_hours AS
    (
        SELECT DISTINCT platform, country, content_id, hour
        FROM changes
        WHERE hour >= first_hour AND hour <= toStartOfHour(tail_until)
    ),
    grid AS
    (
        SELECT
            platform,
            country,
            content_id,
            greatest(watermark, hour) + toIntervalMinute(number) AS minute,
            hour
        FROM dimension_hours
        ARRAY JOIN range(
            dateDiff(
                'minute',
                greatest(watermark, hour),
                least(tail_until, hour + toIntervalHour(1) - toIntervalMinute(1))
            ) + 1
        ) AS number
        WHERE greatest(watermark, hour) <= least(tail_until, hour + toIntervalHour(1) - toIntervalMinute(1))
    ),
    stream AS
    (
        SELECT
            platform,
            country,
            content_id,
            minute,
            hour,
            toUInt8(0) AS position,
            toNullable(concurrency) AS concurrency,
            toUInt8(0) AS is_grid
        FROM changes

        UNION ALL

        SELECT
            platform,
            country,
            content_id,
            minute,
            hour,
            toUInt8(1) AS position,
            CAST(NULL, 'Nullable(Int64)') AS concurrency,
            toUInt8(1) AS is_grid
        FROM grid
    ),
    filled AS
    (
        SELECT
            platform,
            country,
            content_id,
            minute,
            is_grid,
            anyLast(concurrency) OVER
            (
                PARTITION BY platform, country, content_id, hour
                ORDER BY minute, position
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS concurrency
        FROM stream
    )
SELECT
    {run_id:UUID} AS run_id,
    platform,
    country,
    content_id,
    minute,
    toUInt64(concurrency) AS concurrency
FROM filled
WHERE is_grid = 1 AND concurrency > 0;
