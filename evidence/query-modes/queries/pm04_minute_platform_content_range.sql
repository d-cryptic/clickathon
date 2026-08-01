-- pm04 — POINT-IN-TIME, minute grain, multi-dimension (platform AND content_id).
-- Cube level 5. The 1-minute range never touches the hour tier, so the filter is
-- applied to cc_minute_delta directly — any dimension combination works here,
-- including ones that are NOT a cube level.
SELECT
    range_start          AS minute,
    platform, content_id,
    peak                 AS concurrent,
    hours_from_hour_tier AS hrs,
    change_points_from_minute_tier AS chg
FROM v_cc_window_range(
    p_start      = {p_minute:DateTime},
    p_end        = {p_minute:DateTime} + INTERVAL 1 MINUTE,
    p_platform   = {p_platform:String},
    p_country    = '*',
    p_content_id = {p_content_id:Int64})
