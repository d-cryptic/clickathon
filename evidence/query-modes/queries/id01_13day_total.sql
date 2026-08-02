-- id01 — INTERVAL, 13 days, no filter (b10's shape, scratch baseline).
-- Hour-aligned, so the whole answer comes from the hour tier: the read should be
-- IDENTICAL to a 2-hour aligned range (im02) — O(1 granule) in range length.
SELECT
    range_start, range_end, peak, peak_minute, integral,
    round(avg_concurrent, 2) AS avg_concurrent,
    hours_from_hour_tier, change_points_from_minute_tier
FROM v_cc_window_range(
    p_start = {p_start:DateTime}, p_end = {p_end:DateTime},
    p_platform = '*', p_country = '*', p_content_id = -1)
