-- tr03 — THE THIRD TRAP, and the one this task found: densifying a minute curve
-- with WITH FILL across an HOUR BOUNDARY invents viewers.
--
-- docs/CONVENTIONS.md tells a reader to densify a delta view with
--     ORDER BY minute WITH FILL STEP toIntervalSecond(60) INTERPOLATE (concurrent AS concurrent)
-- and that is correct WITHIN one hour (benchmark b06 fills exactly one hour, so
-- it is unaffected). Across hours it is not: deltas are hour-clipped (ADR 0003),
-- so every hour's running sum restarts at 0, and INTERPOLATE has no notion of
-- that partition — it carries the previous hour's closing level into an hour
-- that legitimately opened empty.
--
-- Hour 2026-07-24 13:00 is the case on the provided file. Hour 12 closes at
-- level 1 (an interval running through 12:59, whose close delta lands at 13:00
-- and is therefore clipped OUT of hour 12). Hour 13's first change point is at
-- 13:10. Truth for 13:00-13:09 is 0 viewers; the naive fill says 1.
--
-- Both columns below are computed over the same minutes from the same table.
SELECT
    naive.minute,
    naive.concurrent   AS naive_fill,
    anchored.concurrent AS hour_anchored,
    truth.concurrent   AS interval_expansion_truth
FROM
(
    -- the naive recipe: no hour-start anchor
    SELECT minute, concurrent FROM
    (
        SELECT minute, toInt64(sum(d) OVER (PARTITION BY toStartOfHour(minute) ORDER BY minute
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS concurrent
        FROM (SELECT minute, sum(delta) AS d FROM cc_minute_delta
              WHERE minute >= {p_from:DateTime} AND minute < {p_to:DateTime} GROUP BY minute)
    )
    ORDER BY minute ASC WITH FILL FROM {p_from:DateTime} TO {p_to:DateTime} STEP toIntervalMinute(1)
    INTERPOLATE (concurrent AS concurrent)
) AS naive
LEFT JOIN
(
    -- the corrected recipe: every hour start gets an explicit 0-delta anchor
    SELECT minute, concurrent FROM
    (
        SELECT minute, toInt64(sum(d) OVER (PARTITION BY toStartOfHour(minute) ORDER BY minute
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS concurrent
        FROM
        (
            SELECT minute, sum(d) AS d FROM
            (
                SELECT minute, sum(delta) AS d FROM cc_minute_delta
                WHERE minute >= {p_from:DateTime} AND minute < {p_to:DateTime} GROUP BY minute
                UNION ALL
                SELECT toDateTime(arrayJoin(range(toUInt32({p_from:DateTime}),
                                                  toUInt32({p_to:DateTime}), 3600))) AS minute,
                       toInt64(0) AS d
            ) GROUP BY minute
        )
    )
    ORDER BY minute ASC WITH FILL FROM {p_from:DateTime} TO {p_to:DateTime} STEP toIntervalMinute(1)
    INTERPOLATE (concurrent AS concurrent)
) AS anchored USING (minute)
LEFT JOIN v_concurrency_minute_intervals AS truth USING (minute)
WHERE naive.minute >= {p_focus_from:DateTime} AND naive.minute < {p_focus_to:DateTime}
ORDER BY naive.minute
