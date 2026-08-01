-- Aggregates the parameterized serving curve. See concurrency_curve.sql for
-- parameter and semantic details. Average is minute-weighted and includes zeroes.
-- `as_of_run_sequence` selects historical correction state.

WITH
    toDateTime({from:String}, 'UTC') AS from_minute,
    toDateTime({to:String}, 'UTC') AS to_minute,
    grid AS
    (
        SELECT
            from_minute + toIntervalMinute(number) AS minute,
            toStartOfHour(from_minute + toIntervalMinute(number)) AS hour
        FROM numbers(dateDiff('minute', from_minute, to_minute) + 1)
    ),
    published_runs AS
    (
        SELECT run_id
        FROM finalizer_run_log
        GROUP BY run_id
        HAVING
            max(phase) = 'published'
            AND max(run_sequence) <= {as_of_run_sequence:UInt64}
    ),
    selected_finalizer_sequence AS
    (
        SELECT max(run_sequence) AS finalizer_sequence
        FROM finalizer_run_log
        WHERE run_id IN published_runs
    ),
    tail_runs AS
    (
        SELECT
            run_id,
            max(run_sequence) AS tail_sequence,
            max(event_watermark) AS event_watermark,
            max(tail_until) AS tail_until
        FROM exact_tail_run_log
        GROUP BY run_id
        HAVING
            max(phase) = 'published'
            AND max(finalizer_run_sequence) = (SELECT finalizer_sequence FROM selected_finalizer_sequence)
    ),
    selected_tail AS
    (
        SELECT
            argMax(run_id, tail_sequence) AS run_id,
            argMax(event_watermark, tail_sequence) AS event_watermark,
            argMax(tail_until, tail_sequence) AS tail_until
        FROM tail_runs
        HAVING count() > 0
    ),
    tail_window AS
    (
        SELECT if(
            count() = 0,
            toDateTime('2100-01-01 00:00:00', 'UTC'),
            any(event_watermark)
        ) AS event_watermark,
        if(
            count() = 0,
            toDateTime('1970-01-01 00:00:00', 'UTC'),
            any(tail_until)
        ) AS tail_until
        FROM selected_tail
    ),
    correction_deltas AS
    (
        SELECT minute, sum(correction_delta) AS delta
        FROM
        (
            SELECT
                video_session_id,
                platform,
                country,
                content_id,
                minute,
                argMax(correction_delta, run_sequence) AS correction_delta
            FROM session_delta_correction_stage
            WHERE
                minute >= toStartOfHour(from_minute)
                AND minute <= to_minute
                AND run_id IN published_runs
                AND ({platform:String} = '' OR platform = {platform:String})
                AND ({country:String} = '' OR country = {country:String})
                AND ({content_id:String} = '' OR content_id = toInt64OrNull({content_id:String}))
                AND
                (
                    {video_type:String} = ''
                    OR content_id IN
                    (
                        SELECT content_id
                        FROM content_dim FINAL
                        WHERE video_type = {video_type:String}
                    )
                )
            GROUP BY video_session_id, platform, country, content_id, minute
        )
        GROUP BY minute
    ),
    deltas AS
    (
        SELECT minute, sum(delta) AS delta
        FROM
        (
            SELECT minute, delta
            FROM cc_minute_delta
            WHERE
                minute >= toStartOfHour(from_minute)
                AND minute <= to_minute
                AND ({platform:String} = '' OR platform = {platform:String})
                AND ({country:String} = '' OR country = {country:String})
                AND ({content_id:String} = '' OR content_id = toInt64OrNull({content_id:String}))
                AND
                (
                    {video_type:String} = ''
                    OR content_id IN
                    (
                        SELECT content_id
                        FROM content_dim FINAL
                        WHERE video_type = {video_type:String}
                    )
                )

            UNION ALL

            SELECT minute, delta
            FROM correction_deltas
        )
        GROUP BY minute
    ),
    changes AS
    (
        SELECT
            minute,
            toStartOfHour(minute) AS hour,
            sum(delta) OVER
            (
                PARTITION BY toStartOfHour(minute)
                ORDER BY minute
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS concurrency
        FROM deltas
    ),
    baseline_curve AS
    (
        SELECT grid.minute, ifNull(changes.concurrency, 0) AS concurrency
        FROM grid
        ASOF LEFT JOIN changes
            ON grid.hour = changes.hour
           AND grid.minute >= changes.minute
    ),
    tail_concurrency AS
    (
        SELECT minute, sum(concurrency) AS concurrency
        FROM exact_tail_minute_stage
        WHERE
            run_id = (SELECT run_id FROM selected_tail)
            AND minute >= from_minute
            AND minute <= to_minute
            AND ({platform:String} = '' OR platform = {platform:String})
            AND ({country:String} = '' OR country = {country:String})
            AND ({content_id:String} = '' OR content_id = toInt64OrNull({content_id:String}))
            AND
            (
                {video_type:String} = ''
                OR content_id IN
                (
                    SELECT content_id
                    FROM content_dim FINAL
                    WHERE video_type = {video_type:String}
                )
            )
        GROUP BY minute
    ),
    curve AS
    (
        SELECT if(
            baseline_curve.minute >= (SELECT event_watermark FROM tail_window)
            AND baseline_curve.minute <= (SELECT tail_until FROM tail_window),
            toInt64(ifNull(tail_concurrency.concurrency, 0)),
            baseline_curve.concurrency
        ) AS concurrency
        FROM baseline_curve
        LEFT JOIN tail_concurrency USING (minute)
    )
SELECT
    max(concurrency) AS peak_concurrency,
    avg(concurrency) AS average_concurrency,
    sum(concurrency) AS concurrency_minutes,
    count() AS minute_count
FROM curve;
