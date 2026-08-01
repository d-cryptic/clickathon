-- pm02 — POINT-IN-TIME, minute grain, no filter — the DIRECT form.
-- Level at M = sum of every hour-clipped delta from toStartOfHour(M) through M
-- (ADR 0003 makes each hour absolute, so the sum needs no carry-in and no window
-- function). sum() over an empty set is 0, so an idle minute answers 0, not NULL.
SELECT toInt64(sum(delta)) AS concurrent
FROM cc_minute_delta
WHERE minute >= toStartOfHour({p_minute:DateTime})
  AND minute <= {p_minute:DateTime}
