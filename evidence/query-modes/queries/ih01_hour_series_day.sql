-- ih01 — INTERVAL, hour SERIES for one day (b05's shape, scratch baseline).
-- Stored rows of cc_hour_agg at the headline cube level.
SELECT hour, peak, peak_minute, integral, round(avg_concurrent, 2) AS avg_concurrent
FROM v_concurrency_hour_total
WHERE hour >= {p_day:DateTime}
  AND hour <  {p_day:DateTime} + INTERVAL 1 DAY
ORDER BY hour
