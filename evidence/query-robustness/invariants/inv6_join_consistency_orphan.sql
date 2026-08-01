-- inv6 — JOIN CONSISTENCY: a content_id with no catalog row must not silently
-- vanish from video-type rollups. The b08 shape filters via `content_id IN
-- (SELECT ... FROM content_dim WHERE video_type = X)`, so an orphan session is
-- in NO video_type bucket, and the sum of all per-type integrals undercounts
-- the total by exactly the orphan contribution. Inside any single b08 answer
-- that loss is INVISIBLE; this check makes it a number. PASS here means
-- "measured and accounted for", with the orphan share reported — it is a
-- property to disclose, not a bug to fix silently.
WITH
    per_session AS
    (
        SELECT
            content_id,
            -- uniqExact of (session, minute): a session with two intervals
            -- touching the same minute is one viewer that minute, not two
            60 * uniqExact(video_session_id, m) AS integral_s
        FROM
        (
            SELECT video_session_id, content_id,
                   arrayJoin(range(
                       toUInt32(toStartOfMinute(interval_start)),
                       toUInt32(toStartOfMinute(interval_end)) + 60, 60)) AS m
            FROM session_intervals FINAL
        )
        GROUP BY content_id
    ),
    (SELECT sum(integral_s) FROM per_session) AS total_integral,
    (SELECT sum(integral_s) FROM per_session
      WHERE content_id IN (SELECT content_id FROM content_dim)) AS catalogued_integral
SELECT
    'join_consistency_orphan'                        AS invariant,
    total_integral,
    catalogued_integral,
    total_integral - catalogued_integral             AS orphan_integral,
    round(100.0 * (total_integral - catalogued_integral)
          / greatest(total_integral, 1), 3)          AS orphan_pct,
    (SELECT groupArray(DISTINCT content_id) FROM per_session
      WHERE content_id NOT IN (SELECT content_id FROM content_dim)) AS orphan_content_ids,
    if(total_integral = catalogued_integral,
       'PASS: no orphans on this dataset',
       'PASS-WITH-DISCLOSURE: orphan watch time exists and is excluded from every video_type answer') AS verdict
