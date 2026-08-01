-- amb02 — the same ambiguity one grain up, plus a fourth reading that only
-- exists at day grain: which DENOMINATOR the average uses.
--
--   A  peak within D              max over the day's hours
--   B  average across D           integral / 86,400 — the full nominal day
--   B' average over active hours  integral / (active_hours * 3600)
--   C  the level at 00:00         a MINUTE-mode question
--
-- B vs B' is not pedantry: the first and last day of any feed are genuinely
-- partial, and 2026-07-26 is a partial day (data stops at 11:32). B says 92.1,
-- B' says 184.21 — a 2x spread on the same stored integral. We serve B as the
-- headline because a day with nobody watching is genuinely zero-concurrency
-- time, and expose active_hours + integral so B' is one division away.
SELECT
    {p_day:Date} AS day,
    (SELECT peak        FROM v_concurrency_day_total WHERE day = {p_day:Date}) AS a_peak_within_day,
    (SELECT peak_minute FROM v_concurrency_day_total WHERE day = {p_day:Date}) AS a_peak_minute,
    (SELECT round(avg_concurrent, 2)
                        FROM v_concurrency_day_total WHERE day = {p_day:Date}) AS b_avg_full_86400s,
    (SELECT active_hours FROM v_concurrency_day_total WHERE day = {p_day:Date}) AS active_hours,
    (SELECT round(integral / (active_hours * 3600), 2)
                        FROM v_concurrency_day_total WHERE day = {p_day:Date}) AS b_prime_avg_active_hours_only,
    (SELECT integral    FROM v_concurrency_day_total WHERE day = {p_day:Date}) AS integral_seconds,
    (SELECT toInt64(sum(delta)) FROM cc_minute_delta
      WHERE minute = {p_day_dt:DateTime})                                      AS c_level_at_midnight
