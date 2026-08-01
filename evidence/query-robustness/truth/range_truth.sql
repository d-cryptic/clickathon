-- ============================================================================
-- truth/range_truth.sql — INDEPENDENT ground truth for peak / integral over an
-- arbitrary [p_start, p_end) at any (platform, country, content_id) filter.
-- Deliberately a DIFFERENT arithmetic from the serving layer: expand
-- session_intervals to minutes, count uniqExact(video_session_id) per minute,
-- clip each minute's 60 s to the range at second precision. Same parameter
-- convention as v_cc_window_range ('*' / -1 mean "no filter") because it is the
-- view's INTERFACE being tested. O(sessions x minutes) — fine on a fixture,
-- never a serving path.
-- Minute membership matches the model: an interval is active from
-- toStartOfMinute(start) through toStartOfMinute(end) INCLUSIVE.
-- ============================================================================
WITH
    toDateTime({p_start:DateTime}) AS rs,
    toDateTime({p_end:DateTime})   AS re,
    per_minute AS
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
            WHERE (({p_platform:String}  = '*') OR (platform   = {p_platform:String}))
              AND (({p_country:String}   = '*') OR (country    = {p_country:String}))
              AND (({p_content_id:Int64} = -1)  OR (content_id = {p_content_id:Int64}))
              -- set filters for the b08/b09 shapes; empty array = no filter
              AND (empty({p_platforms:Array(String)}) OR (platform   IN {p_platforms:Array(String)}))
              AND (empty({p_contents:Array(Int64)})   OR (content_id IN {p_contents:Array(Int64)}))
        )
        GROUP BY minute
    ),
    clipped AS
    (
        SELECT
            minute,
            c,
            toInt64(least(toUInt32(minute) + 60, toUInt32(re)))
              - toInt64(greatest(toUInt32(minute), toUInt32(rs))) AS ov
        FROM per_minute
        WHERE least(toUInt32(minute) + 60, toUInt32(re))
            > greatest(toUInt32(minute), toUInt32(rs))
    )
SELECT
    toInt64(max(c))                                             AS peak,
    argMax(greatest(minute, rs), (c, -toInt64(toUInt32(minute)))) AS peak_minute,
    toInt64(sum(c * ov))                                        AS integral,
    round(sum(c * ov) / (toUInt32(re) - toUInt32(rs)), 6)       AS avg_concurrent
FROM clipped
