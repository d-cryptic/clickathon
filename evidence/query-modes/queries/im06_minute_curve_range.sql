-- im06 — INTERVAL, the minute CURVE over a ragged range (10:17 -> 11:31), no filter.
-- b06 generalised across hours: change points from toStartOfHour(start) so the
-- lead-in level at the ragged start is correct, running sum PARTITIONed BY hour
-- (docs/CONVENTIONS.md), WITH FILL to densify, and the lead-in minutes dropped
-- at the END. Interpolation across an hour boundary is safe ONLY because of
-- hour-clipping: the level at the end of hour H always equals the level at
-- H+1:00 (every surviving interval re-opens with +1 at the boundary).
SELECT minute, concurrent
FROM
(
    SELECT minute, concurrent
    FROM
    (
        SELECT
            minute,
            toInt64(sum(d) OVER (
                PARTITION BY toStartOfHour(minute)
                ORDER BY minute
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS concurrent
        FROM
        (
            SELECT minute, sum(delta) AS d
            FROM cc_minute_delta
            WHERE minute >= toStartOfHour({p_start:DateTime})
              AND minute <  {p_end:DateTime}
            GROUP BY minute
        )
    )
    ORDER BY minute ASC WITH FILL
        FROM toStartOfHour({p_start:DateTime})
        TO   {p_end:DateTime}
        STEP toIntervalMinute(1)
    INTERPOLATE (concurrent AS concurrent)
)
WHERE minute >= {p_start:DateTime}
ORDER BY minute
