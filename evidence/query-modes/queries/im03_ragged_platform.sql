-- im03 — INTERVAL, ragged range, one dimension (platform).
-- The hour-tier branch pins the cube level by equality; the partial-hour minute
-- scan filters cc_minute_delta on its sort-key prefix.
SELECT
    range_start, range_end, platform, peak, peak_minute, integral,
    round(avg_concurrent, 2) AS avg_concurrent,
    hours_from_hour_tier, change_points_from_minute_tier
FROM v_cc_window_range(
    p_start = {p_start:DateTime}, p_end = {p_end:DateTime},
    p_platform = {p_platform:String}, p_country = '*', p_content_id = -1)
