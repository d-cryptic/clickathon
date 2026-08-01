-- The invariant under the OLD attribution, computed INLINE so it does not
-- depend on a scratch database that still carries the pre-ADR-0031 user tier:
-- users expanded PER RAW INTERVAL (what sql/45 used to do), sessions from the
-- delta tier's hour-resolved running sum (what sql/40 does, unchanged).
--
-- The session level is resolved INSIDE the minute's own hour by summing
-- `d.minute <= u.minute`. A naive window function over the sparse delta rows
-- reports 75,297 false violations instead of 82 — that is U3-F1 in miniature.
WITH
    usr AS (
        SELECT toDateTime(m) AS minute, platform, country, content_id,
               uniqExact(user_id) AS users
        FROM (
            SELECT user_id, platform, country, content_id,
                   arrayJoin(range(toUInt32(toStartOfMinute(interval_start)),
                                   toUInt32(toStartOfMinute(interval_end)) + 1, 60)) AS m
            FROM session_intervals FINAL
        )
        GROUP BY minute, platform, country, content_id
    ),
    dl AS (
        SELECT minute, platform, country, content_id, sum(delta) AS d
        FROM cc_minute_delta GROUP BY minute, platform, country, content_id
    ),
    cmp AS (
        SELECT u.minute AS minute, u.platform AS platform, u.country AS country,
               u.content_id AS content_id, any(u.users) AS users,
               toInt64(sum(if(d.minute <= u.minute, d.d, 0))) AS sessions
        FROM usr AS u
        LEFT JOIN dl AS d
          ON  d.platform = u.platform AND d.country = u.country
          AND d.content_id = u.content_id
          AND toStartOfHour(d.minute) = toStartOfHour(u.minute)
        GROUP BY minute, platform, country, content_id
    )
SELECT count() AS cells_with_users, countIf(users > sessions) AS violating_cells,
       max(users - sessions) AS worst_excess,
       countIf(users > sessions AND sessions = 0) AS cells_with_zero_sessions,
       uniqExactIf(minute, users > sessions) AS distinct_minutes
FROM cmp;
