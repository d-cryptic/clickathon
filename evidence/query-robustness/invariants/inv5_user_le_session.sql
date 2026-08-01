-- inv5 — USER CONCURRENCY <= SESSION CONCURRENCY at every (minute, filter
-- grain), across the WHOLE cube: all 8 dimension subsets of (platform,
-- country, content_id), every minute, every combination. A user runs >= 1
-- session, so the user count can never exceed the session count at the same
-- grain; a single violation anywhere means one of the two tiers is deeply
-- wrong. User side: the SERVING tier (cc_user_minute states, set-unioned to
-- each coarser grain — legal for uniqExact states). Session side: independent
-- interval expansion. Missing session rows count as 0, so a user-minute row
-- with no session coverage is a violation, not a dropped join. One row per
-- cube mask.
WITH
    sessions AS
    (
        SELECT lv_platform, lv_country, lv_content_id, g, minute,
               uniqExact(video_session_id) AS session_c
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
    ),
    users AS
    (
        SELECT
            if(bitAnd(g, 1) = 1, platform,   '*') AS lv_platform,
            if(bitAnd(g, 2) = 2, country,    '*') AS lv_country,
            if(bitAnd(g, 4) = 4, content_id, -1)  AS lv_content_id,
            g,
            minute,
            uniqExactMerge(active_state) AS user_c
        FROM cc_user_minute FINAL
        ARRAY JOIN [0, 1, 2, 3, 4, 5, 6, 7] AS g
        GROUP BY lv_platform, lv_country, lv_content_id, g, minute
    )
SELECT
    g                                            AS cube_mask,
    count()                                      AS cells_compared,
    countIf(user_c > coalesce(s.session_c, 0))   AS violations,
    max(user_c - coalesce(s.session_c, 0))       AS max_excess,
    if(countIf(user_c > coalesce(s.session_c, 0)) = 0, 'PASS', 'FAIL') AS verdict
FROM users
LEFT JOIN sessions AS s
    ON  s.lv_platform = users.lv_platform AND s.lv_country = users.lv_country
    AND s.lv_content_id = users.lv_content_id AND s.g = users.g
    AND s.minute = users.minute
GROUP BY g
ORDER BY g
