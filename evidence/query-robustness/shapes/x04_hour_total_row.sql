-- x04 — one stored hour row from the headline hour tier, with its peak_minute.
-- Used to probe the ADR 0014 tie-break (a designed hour whose peak level is
-- reached in two different minutes must report the EARLIEST) and zero-hour
-- emptiness (an hour with no viewers must be absent, not a zero row).
SELECT hour, peak, peak_minute, integral
FROM v_concurrency_hour_total
WHERE hour = {p_hour:DateTime}
