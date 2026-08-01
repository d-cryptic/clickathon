-- im06 — INTERVAL, the minute CURVE over a ragged range (10:17 -> 11:31), no filter.
-- b06 generalised to a range that CROSSES HOUR BOUNDARIES, which is where the
-- naive densify recipe breaks — finding F1, evidence/query-modes/correctness.txt.
--
-- THE HOUR-START ANCHOR IS NOT OPTIONAL. docs/CONVENTIONS.md's densify pattern
--     ORDER BY minute WITH FILL STEP 60 INTERPOLATE (concurrent AS concurrent)
-- carries the last known level forward across an hour boundary. Deltas are
-- hour-clipped (ADR 0003), so each hour's running sum RESTARTS at 0: an hour
-- whose first change point is at :10 stood at level 0 from :00 to :09, but the
-- interpolation carries the PREVIOUS hour's closing level into those minutes.
-- MEASURED on the provided file: 10 phantom minutes in hour 2026-07-24 13:00,
-- where the naive curve reports 1 viewer and the interval expansion — the
-- independent truth — reports none. An earlier draft of this very file claimed
-- the crossing was "safe ONLY because of hour-clipping, the level at the end of
-- hour H always equals the level at H+1:00". That is false whenever an interval
-- ends in H's last minute: its close delta lands at H+1:00, outside H, so H
-- keeps its nonzero closing level while H+1 legitimately opens empty.
--
-- The fix is one UNION ALL: give every hour start inside the range an explicit
-- 0-delta row. The running sum at :00 then equals that hour's true opening level,
-- and WITH FILL can only ever interpolate forward from a correct anchor. This is
-- the same class of error as forgetting PARTITION BY toStartOfHour(minute) — the
-- window function here HAS the partition; the FILL did not.
--
-- Lead-in: change points are read from toStartOfHour(p_start) so the level at a
-- ragged start is correct; the lead-in minutes are dropped at the END.
WITH
    anchors AS
    (
        SELECT
            toDateTime(arrayJoin(range(toUInt32(toStartOfHour({p_start:DateTime})),
                                       toUInt32({p_end:DateTime}),
                                       3600))) AS minute,
            toInt64(0) AS d
    ),
    change_points AS
    (
        SELECT minute, sum(delta) AS d
        FROM cc_minute_delta
        WHERE minute >= toStartOfHour({p_start:DateTime})
          AND minute <  {p_end:DateTime}
        GROUP BY minute
    ),
    merged AS
    (
        SELECT minute, sum(d) AS d
        FROM (SELECT minute, d FROM change_points UNION ALL SELECT minute, d FROM anchors)
        GROUP BY minute
    )
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
        FROM merged
    )
    ORDER BY minute ASC WITH FILL
        FROM toStartOfHour({p_start:DateTime})
        TO   {p_end:DateTime}
        STEP toIntervalMinute(1)
    INTERPOLATE (concurrent AS concurrent)
)
WHERE minute >= {p_start:DateTime}
ORDER BY minute
