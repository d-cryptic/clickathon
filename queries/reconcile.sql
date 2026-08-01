-- Rebuild foreground intervals from ev_raw in this client session, then compare
-- five representative minutes with the signed-delta serving layer.  Temporary
-- tables make this deliberately independent of session_intervals.

CREATE TEMPORARY TABLE raw_truth_intervals
ENGINE = Memory
AS
WITH
    150 AS heartbeat_gap_s,
    60 AS tail_grace_s,
    toDateTime64(0, 3) AS epoch,
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
    raw_intervals AS
    (
        SELECT
            video_session_id,
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
    )
SELECT
    video_session_id,
    interval_start,
    least(
        last_signal_at + toIntervalSecond(tail_grace_s),
        if(first_stop_at = epoch, last_signal_at + toIntervalSecond(tail_grace_s), first_stop_at),
        if(next_dimension_change_at = epoch, last_signal_at + toIntervalSecond(tail_grace_s), next_dimension_change_at)
    ) AS interval_end
FROM raw_intervals
WHERE interval_start < interval_end;

CREATE TEMPORARY TABLE reconcile_minutes
ENGINE = Memory
AS
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
        SELECT minute, argMax(correction_delta, run_sequence) AS delta
        FROM session_delta_correction_stage
        WHERE run_id IN published_runs
        GROUP BY video_session_id, platform, country, content_id, minute
    ),
    serving_deltas AS
    (
        SELECT minute, sum(delta) AS delta
        FROM
        (
            SELECT minute, delta FROM cc_minute_delta
            UNION ALL
            SELECT minute, delta FROM correction_state
        )
        GROUP BY minute
    ),
    bounds AS
    (
        SELECT min(interval_start) AS first_event, max(interval_end) AS last_event
        FROM raw_truth_intervals
    ),
    range_samples AS
    (
        SELECT toDateTime(toStartOfMinute(first_event + toIntervalSecond(
            intDiv(dateDiff('second', first_event, last_event) * slot, 3)
        ))) AS minute
        FROM bounds
        ARRAY JOIN range(4) AS slot
    ),
    peak_sample AS
    (
        SELECT minute
        FROM
        (
            SELECT
                minute,
                sum(delta) OVER
                (
                    PARTITION BY toStartOfHour(minute)
                    ORDER BY minute
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                ) AS concurrency
            FROM
            (
                SELECT minute, delta
                FROM serving_deltas
            )
        )
        ORDER BY concurrency DESC, minute ASC
        LIMIT 1
    )
SELECT DISTINCT minute
FROM
(
    SELECT minute FROM range_samples
    UNION ALL
    SELECT minute FROM peak_sample
);

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
        SELECT minute, argMax(correction_delta, run_sequence) AS delta
        FROM session_delta_correction_stage
        WHERE run_id IN published_runs
        GROUP BY video_session_id, platform, country, content_id, minute
    ),
    serving_deltas AS
    (
        SELECT minute, sum(delta) AS delta
        FROM
        (
            SELECT minute, delta FROM cc_minute_delta
            UNION ALL
            SELECT minute, delta FROM correction_state
        )
        GROUP BY minute
    ),
    truth AS
    (
        SELECT
            samples.minute,
            countIf(
                intervals.interval_start < samples.minute + toIntervalMinute(1)
                AND intervals.interval_end > samples.minute
            ) AS truth
        FROM reconcile_minutes AS samples
        CROSS JOIN raw_truth_intervals AS intervals
        GROUP BY samples.minute
    ),
    served AS
    (
        SELECT
            samples.minute,
            sumIf(
                deltas.delta,
                deltas.minute >= toStartOfHour(samples.minute)
                AND deltas.minute <= samples.minute
            ) AS served
        FROM reconcile_minutes AS samples
        CROSS JOIN serving_deltas AS deltas
        GROUP BY samples.minute
    )
SELECT
    truth.minute,
    truth.truth,
    served.served,
    served.served - truth.truth AS delta,
    if(served.served = truth.truth, 'PASS', 'FAIL') AS result
FROM truth
INNER JOIN served USING (minute)
ORDER BY minute;
