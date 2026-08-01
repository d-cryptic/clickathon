-- inv2 — DISTINCT USERS ARE NEVER SUMMED ACROSS DIMENSIONS (rule 2).
-- Per minute: true distinct users (interval expansion, uniqExact over user_id)
-- vs the WRONG figure (sum of per-platform distinct-user counts) vs the SERVING
-- figure (cc_user_minute states set-unioned across all dimension rows).
-- PASS requires: serving == truth on every minute, AND at least one minute
-- where the summed figure overcounts (a user watching two platforms in the
-- same minute) so the trap is demonstrated, not assumed.
WITH
    truth AS
    (
        SELECT minute, uniqExact(user_id) AS users_true
        FROM
        (
            SELECT user_id,
                   toDateTime(arrayJoin(range(
                       toUInt32(toStartOfMinute(interval_start)),
                       toUInt32(toStartOfMinute(interval_end)) + 60, 60))) AS minute
            FROM session_intervals FINAL
        )
        GROUP BY minute
    ),
    summed AS
    (
        SELECT minute, sum(u) AS users_summed
        FROM
        (
            SELECT platform, minute, uniqExact(user_id) AS u
            FROM
            (
                SELECT user_id, platform,
                       toDateTime(arrayJoin(range(
                           toUInt32(toStartOfMinute(interval_start)),
                           toUInt32(toStartOfMinute(interval_end)) + 60, 60))) AS minute
                FROM session_intervals FINAL
            )
            GROUP BY platform, minute
        )
        GROUP BY minute
    ),
    serving AS
    (
        SELECT minute, uniqExactMerge(active_state) AS users_serving
        FROM cc_user_minute FINAL
        GROUP BY minute
    )
    ,(SELECT count() FROM serving WHERE minute NOT IN (SELECT minute FROM truth))
                                                               AS extra_serving_minutes
SELECT
    'users_never_summed'                                       AS invariant,
    count()                                                    AS minutes_compared,
    -- LEFT JOIN, not INNER: a minute the serving tier LOST must count as a
    -- mismatch (users_serving reads 0 there), not silently drop out of the join.
    countIf(coalesce(serving.users_serving, 0) != users_true)  AS serving_mismatch_minutes,
    extra_serving_minutes,
    countIf(users_summed > users_true)                         AS minutes_where_sum_overcounts,
    max(users_summed - users_true)                             AS max_overcount,
    if((countIf(coalesce(serving.users_serving, 0) != users_true) > 0)
        OR (extra_serving_minutes > 0),
       'FAIL: serving user tier disagrees with interval truth',
       if(countIf(users_summed > users_true) = 0,
          'FAIL: dataset cannot demonstrate the trap (sum never overcounts)',
          'PASS'))                                             AS verdict
FROM truth
LEFT JOIN summed  USING (minute)
LEFT JOIN serving USING (minute)
