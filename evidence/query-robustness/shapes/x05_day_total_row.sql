-- x05 — one day-grain row from v_concurrency_day_total. Used for the
-- hand-computed day check: the fixture's day-1 truth is peak 8 first reached
-- at 10:30, integral exactly 33,000 concurrency-seconds.
SELECT day, peak, peak_minute, integral, round(avg_concurrent, 4) AS avg_concurrent
FROM v_concurrency_day_total
WHERE day = {p_day:Date}
