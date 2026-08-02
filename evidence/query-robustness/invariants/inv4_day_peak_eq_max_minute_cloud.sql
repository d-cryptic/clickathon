-- inv4 (cloud, sentinel-pinned) — the same day-peak-equals-max-minute check
-- against the GRADED serving layer, which predates ADR 0022 and has no
-- cube_level column, so the four practically-queryable levels are pinned by
-- display sentinels (safe there: the smallest real content_id in the graded
-- file is 20,971,538 — no collision). Masks: 0 total, 1 platform, 2 country,
-- 4 content. READ-ONLY.
WITH
    truth AS
    (
        SELECT
            lv_platform AS platform, lv_country AS country,
            lv_content_id AS content_id, g,
            toDate(minute) AS day,
            max(c) AS peak_truth
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
                ARRAY JOIN [0, 1, 2, 4] AS g
            )
            GROUP BY lv_platform, lv_country, lv_content_id, g, minute
        )
        GROUP BY platform, country, content_id, g, day
    )
SELECT
    g                                                AS filter_level,
    count()                                          AS rows_compared,
    countIf(coalesce(d.peak, -1) != peak_truth)      AS peak_mismatch,
    if(countIf(coalesce(d.peak, -1) != peak_truth) = 0, 'PASS', 'FAIL') AS verdict
FROM truth
FULL OUTER JOIN
(
    SELECT platform, country, content_id, day, peak,
           multiIf(platform != '*' AND country = '*' AND content_id = -1, 1,
                   platform = '*' AND country != '*' AND content_id = -1, 2,
                   platform = '*' AND country = '*' AND content_id != -1, 4,
                   platform = '*' AND country = '*' AND content_id = -1, 0,
                   -1) AS g
    FROM v_concurrency_day
    WHERE multiIf(platform != '*' AND country = '*' AND content_id = -1, 1,
                  platform = '*' AND country != '*' AND content_id = -1, 2,
                  platform = '*' AND country = '*' AND content_id != -1, 4,
                  platform = '*' AND country = '*' AND content_id = -1, 0,
                  -1) IN (0, 1, 2, 4)
) AS d
USING (platform, country, content_id, g, day)
GROUP BY g
ORDER BY g
