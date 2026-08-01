-- ph01 — POINT-IN-TIME, hour grain, no filter. "What was concurrency at hour H?"
-- Our stated definition (docs/QUERY_MODES.md / ADR 0027): the question is
-- ambiguous — peak within H, average across H, or the value at H:00 — so the
-- answer is the STORED HOUR ROW carrying all three readings explicitly:
-- peak (+ peak_minute), avg_concurrent, and the value at H:00 is a MINUTE-mode
-- question (pm01 at M = H). One stored row, sort-key prefix read.
SELECT hour, peak, peak_minute, integral, round(avg_concurrent, 2) AS avg_concurrent
FROM v_concurrency_hour_total
WHERE hour = {p_hour:DateTime}
