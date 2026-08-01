-- ============================================================================
-- truth/series_truth.sql — INDEPENDENT per-minute concurrency series for
-- [p_from, p_to), optional platform filter ('*' = none). Expansion +
-- uniqExact, densified to every minute of the range (absent minute = 0), so it
-- is directly diffable against the b06/b07 dashboard-curve output.
-- ============================================================================
WITH
    toDateTime({p_from:DateTime}) AS rf,
    toDateTime({p_to:DateTime})   AS rt
SELECT
    grid.minute AS minute,
    toInt64(coalesce(observed.c, 0)) AS concurrent
FROM
(
    SELECT toDateTime(arrayJoin(range(toUInt32(rf), toUInt32(rt), 60))) AS minute
) AS grid
LEFT JOIN
(
    SELECT
        minute,
        uniqExact(video_session_id) AS c
    FROM
    (
        SELECT
            video_session_id,
            toDateTime(arrayJoin(range(
                toUInt32(toStartOfMinute(interval_start)),
                toUInt32(toStartOfMinute(interval_end)) + 60,
                60))) AS minute
        FROM session_intervals FINAL
        WHERE (({p_platform:String} = '*') OR (platform = {p_platform:String}))
    )
    GROUP BY minute
) AS observed USING (minute)
ORDER BY minute
