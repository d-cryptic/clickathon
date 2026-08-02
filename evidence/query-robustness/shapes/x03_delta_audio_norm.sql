-- x03 — the same minute-tier peak through the ADR 0011 rule: norm_lang() on
-- BOTH sides of the equality, so any raw spelling of the language matches.
-- The delta between x02 and x03 on the same parameters IS the correctness
-- hole the normalisation rule exists to close.
WITH change_points AS
(
    SELECT
        toStartOfHour(minute) AS hour,
        minute,
        sum(delta) AS d
    FROM cc_minute_delta
    WHERE minute >= {p_start:DateTime}
      AND minute <  {p_end:DateTime}
      AND norm_lang(audio_language) = norm_lang({p_audio:String})
    GROUP BY hour, minute
)
SELECT toInt64(max(c)) AS peak
FROM
(
    SELECT sum(d) OVER (PARTITION BY hour ORDER BY minute
                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS c
    FROM change_points
)
