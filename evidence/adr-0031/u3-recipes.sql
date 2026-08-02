-- Both recipes over the whole file, against per-minute truth expanded from
-- session_intervals. LO/HI derived from the data, as the gate does.
WITH
    (SELECT toStartOfMinute(min(event_timestamp)) FROM ev_raw) AS LO,
    (SELECT toStartOfMinute(max(event_timestamp)) + 60 FROM ev_raw) AS HI,
    truth AS (
        SELECT toDateTime(m) AS minute, uniqExact(video_session_id) AS truth
        FROM (SELECT video_session_id,
                     arrayJoin(range(toUInt32(toStartOfMinute(interval_start)),
                                     toUInt32(toStartOfMinute(interval_end)) + 1, 60)) AS m
              FROM session_intervals FINAL)
        GROUP BY minute
    ),
    naive AS (
        SELECT minute, concurrent FROM (
            SELECT minute, toInt64(sum(d) OVER (PARTITION BY toStartOfHour(minute) ORDER BY minute
                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS concurrent
            FROM (SELECT minute, sum(delta) AS d FROM cc_minute_delta GROUP BY minute)
            ORDER BY minute)
        ORDER BY minute WITH FILL STEP toIntervalSecond(60) INTERPOLATE (concurrent AS concurrent)
    ),
    fixed AS (
        SELECT minute, toInt64(sum(d) OVER (PARTITION BY toStartOfHour(minute) ORDER BY minute
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS concurrent
        FROM (SELECT minute, sum(delta) AS d FROM cc_minute_delta GROUP BY minute
              ORDER BY minute WITH FILL FROM toDateTime('2026-07-14 15:43:00') TO toDateTime('2026-07-26 11:31:00') STEP toIntervalSecond(60))
    )
SELECT
    'naive  WITH FILL + INTERPOLATE(level)' AS recipe,
    count() AS minutes, countIf(n.concurrent != ifNull(t.truth, 0)) AS wrong_minutes,
    sum(greatest(n.concurrent - toInt64(ifNull(t.truth, 0)), 0)) AS phantom_viewer_minutes
FROM naive n LEFT JOIN truth t ON t.minute = n.minute
UNION ALL
SELECT
    'fixed  WITH FILL(delta=0) + hour-partitioned running sum',
    count(), countIf(f.concurrent != ifNull(t.truth, 0)),
    sum(greatest(f.concurrent - toInt64(ifNull(t.truth, 0)), 0))
FROM fixed f LEFT JOIN truth t ON t.minute = f.minute
ORDER BY 1;
