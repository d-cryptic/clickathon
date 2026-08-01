-- THE INVARIANT: at the same minute and the same grain, distinct USERS can never
-- exceed distinct SESSIONS — one user may hold several sessions, never the other
-- way round.
--
-- The session level is read the way ADR 0003 requires: the running sum of
-- hour-clipped deltas, resolved INSIDE the minute's own hour. Doing this with a
-- naive window function over the sparse delta rows (no spine) reports 75,297
-- false violations, because a minute with no delta row reads as level 0 — that
-- is U3-F1, and it is why this query sums `d.minute <= u.minute` within the
-- hour instead.
WITH
    usr AS (
        SELECT minute, platform, country, content_id, toInt64(concurrent_users) AS users
        FROM v_user_concurrency_minute
    ),
    dl AS (
        SELECT minute, platform, country, content_id, sum(delta) AS d
        FROM cc_minute_delta GROUP BY minute, platform, country, content_id
    ),
    cmp AS (
        SELECT
            u.minute AS minute, u.platform AS platform, u.country AS country,
            u.content_id AS content_id, any(u.users) AS users,
            toInt64(sum(if(d.minute <= u.minute, d.d, 0))) AS sessions
        FROM usr AS u
        LEFT JOIN dl AS d
          ON  d.platform = u.platform AND d.country = u.country
          AND d.content_id = u.content_id
          AND toStartOfHour(d.minute) = toStartOfHour(u.minute)
        GROUP BY minute, platform, country, content_id
    )
SELECT
    count()                            AS cells_with_users,
    countIf(users > sessions)          AS violating_cells,
    max(users - sessions)              AS worst_excess,
    countIf(users > sessions AND sessions = 0) AS cells_with_zero_sessions,
    uniqExactIf(minute, users > sessions)      AS distinct_minutes
FROM cmp;
