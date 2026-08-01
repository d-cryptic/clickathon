-- pm01 — POINT-IN-TIME, minute grain, no filter. "What was concurrency at minute M?"
-- Canonical recipe: v_cc_window_range over the 1-minute range [M, M+1min).
-- peak == avg_concurrent == the level held during that minute (deltas land on
-- minute boundaries, so the level is constant inside a minute). hrs/chg are the
-- provenance: hrs=0, chg=0 means NO DATA in range — distinguishable from a true 0.
SELECT
    range_start          AS minute,
    peak                 AS concurrent,
    round(avg_concurrent, 2) AS avg_check,
    hours_from_hour_tier AS hrs,
    change_points_from_minute_tier AS chg
FROM v_cc_window_range(
    p_start      = {p_minute:DateTime},
    p_end        = {p_minute:DateTime} + INTERVAL 1 MINUTE,
    p_platform   = '*',
    p_country    = '*',
    p_content_id = -1)
