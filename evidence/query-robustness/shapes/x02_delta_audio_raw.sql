-- x02 — minute-tier peak with a RAW audio_language equality, the filter shape
-- ADR 0011 measured as silently dropping 23.3% of Hindi viewers. This is what
-- a judge writes first when told "there can be more new columns for filtering".
WITH change_points AS
(
    SELECT
        toStartOfHour(minute) AS hour,
        minute,
        sum(delta) AS d
    FROM cc_minute_delta
    WHERE minute >= {p_start:DateTime}
      AND minute <  {p_end:DateTime}
      AND audio_language = {p_audio:String}
    GROUP BY hour, minute
)
SELECT toInt64(max(c)) AS peak
FROM
(
    SELECT sum(d) OVER (PARTITION BY hour ORDER BY minute
                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS c
    FROM change_points
)
