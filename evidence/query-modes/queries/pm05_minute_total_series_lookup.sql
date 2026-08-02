-- pm05 — POINT-IN-TIME via the minute SPINE (anti-recipe, measured for the doc).
-- v_cc_minute_series_total materialises the whole held-level spine and THEN
-- filters one minute out of it: correct answer, but the read does not shrink
-- with the question. Kept as the measured reason pm01/pm02 are the recipes.
SELECT concurrent
FROM v_cc_minute_series_total
WHERE minute = {p_minute:DateTime}
