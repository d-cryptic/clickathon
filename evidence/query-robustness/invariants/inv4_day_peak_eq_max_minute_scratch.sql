-- inv4 (scratch, cube-aware) — DAY PEAK EQUALS THE MAX UNDERLYING MINUTE
-- CONCURRENCY AT THE SAME FILTER LEVEL, for EVERY row of the day tier at
-- EVERY cube level. Truth is the interval expansion (uniqExact per minute per
-- masked dimension tuple, max over the day) — a different arithmetic from the
-- delta running sums the tier stores. cube_level is in the join key (ADR
-- 0022): the fixture carries a REAL content_id = -1, so the display tuple
-- alone is ambiguous by design. One row per cube level; FAIL on any peak or
-- integral mismatch, either direction (missing rows count as mismatches).
WITH
    truth AS
    (
        SELECT
            lv_platform AS platform, lv_country AS country,
            lv_content_id AS content_id, toUInt8(g) AS cube_level,
            toDate(minute) AS day,
            max(c)      AS peak_truth,
            sum(c) * 60 AS integral_truth
        FROM
        (
            SELECT lv_platform, lv_country, lv_content_id, g, minute,
                   uniqExact(video_session_id) AS c
            FROM
            (
                SELECT
                    video_session_id,
                    if(bitAnd(g, 1) = 1, platform,   '*') AS lv_platform,
                    if(bitAnd(g, 2) = 2, country,    '*') AS lv_country,
                    if(bitAnd(g, 4) = 4, content_id, -1)  AS lv_content_id,
                    g,
                    toDateTime(arrayJoin(range(
                        toUInt32(toStartOfMinute(interval_start)),
                        toUInt32(toStartOfMinute(interval_end)) + 60, 60))) AS minute
                FROM session_intervals FINAL
                ARRAY JOIN [0, 1, 2, 3, 4, 5, 6, 7] AS g
            )
            GROUP BY lv_platform, lv_country, lv_content_id, g, minute
        )
        GROUP BY platform, country, content_id, cube_level, day
    )
SELECT
    cube_level,
    count()                                          AS rows_compared,
    countIf(coalesce(d.peak, -1)     != peak_truth)      AS peak_mismatch,
    countIf(coalesce(d.integral, -1) != integral_truth)  AS integral_mismatch,
    if(countIf(coalesce(d.peak, -1) != peak_truth)
       + countIf(coalesce(d.integral, -1) != integral_truth) = 0,
       'PASS', 'FAIL')                               AS verdict
FROM truth
FULL OUTER JOIN
(
    SELECT platform, country, content_id, cube_level, day, peak, integral
    FROM v_concurrency_day
) AS d
USING (platform, country, content_id, cube_level, day)
GROUP BY cube_level
ORDER BY cube_level
