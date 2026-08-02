-- tr02 — THE OTHER TRAP. v_concurrency_minute_delta_total emits a row only where
-- concurrency CHANGES. A point lookup at a minute where the level was merely HELD
-- returns an EMPTY set — which a naive reader books as 0 or "no data". The true
-- level at this minute is 1 (held from 15:43). Point lookups must go through
-- pm01/pm02, never through a change-point view.
SELECT concurrent
FROM v_concurrency_minute_delta_total
WHERE minute = {p_minute:DateTime}
