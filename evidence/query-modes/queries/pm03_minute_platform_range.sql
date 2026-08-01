-- pm03 — POINT-IN-TIME, minute grain, one dimension (platform).
-- Same 1-minute v_cc_window_range call; the platform pin routes the partial-hour
-- minute scan through the sort-key prefix of cc_minute_delta (platform leads).
SELECT
    range_start          AS minute,
    platform,
    peak                 AS concurrent,
    hours_from_hour_tier AS hrs,
    change_points_from_minute_tier AS chg
FROM v_cc_window_range(
    p_start      = {p_minute:DateTime},
    p_end        = {p_minute:DateTime} + INTERVAL 1 MINUTE,
    p_platform   = {p_platform:String},
    p_country    = '*',
    p_content_id = -1)
