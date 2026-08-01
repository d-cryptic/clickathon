-- The ten phantom minutes. The naive recipe is run over a window that STARTS
-- inside the previous, non-empty hour — that is what gives INTERPOLATE a level
-- to carry across the boundary — and only then narrowed to 13:00-13:09, whose
-- truth is 0 active sessions.
SELECT minute, concurrent AS naive_says, 0 AS truth
FROM (
    SELECT minute, concurrent
    FROM (
        SELECT minute,
               toInt64(sum(d) OVER (PARTITION BY toStartOfHour(minute) ORDER BY minute
                                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS concurrent
        FROM (SELECT minute, sum(delta) AS d FROM cc_minute_delta
              WHERE minute >= '2026-07-24 12:00:00' AND minute < '2026-07-24 13:15:00'
              GROUP BY minute)
        ORDER BY minute
    )
    ORDER BY minute WITH FILL STEP toIntervalSecond(60) INTERPOLATE (concurrent AS concurrent)
)
WHERE minute >= '2026-07-24 13:00:00' AND minute < '2026-07-24 13:10:00'
ORDER BY minute;
