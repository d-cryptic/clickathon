-- pd01 — POINT-IN-TIME, day grain, no filter. "What was concurrency on day D?"
-- Same stated definition as the hour case, one grain up: the day row carries
-- peak (+ peak_minute), integral, avg_concurrent and active_hours. avg divides
-- by the full 86,400 s; active_hours exposes partial-day coverage so a caller
-- can divide by observed time instead (first/last day of a feed).
SELECT day, peak, peak_minute, integral, round(avg_concurrent, 2) AS avg_concurrent, active_hours
FROM v_concurrency_day_total
WHERE day = {p_day:Date}
