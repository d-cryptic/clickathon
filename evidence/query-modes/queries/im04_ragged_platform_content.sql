-- im04 — INTERVAL, ragged range, multi-dimension (platform AND content_id).
-- Cube level 5 on the hour tier; both dims filter the minute tier directly.
SELECT
    range_start, range_end, platform, content_id, peak, peak_minute, integral,
    round(avg_concurrent, 2) AS avg_concurrent,
    hours_from_hour_tier, change_points_from_minute_tier
FROM v_cc_window_range(
    p_start = {p_start:DateTime}, p_end = {p_end:DateTime},
    p_platform = {p_platform:String}, p_country = '*', p_content_id = {p_content_id:Int64})
