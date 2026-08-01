-- im02 — INTERVAL, hour-ALIGNED twin of im01 (10:00 -> 12:00), no filter.
-- Whole hours only: the partial-hour set is empty, the minute-tier branch prunes
-- to nothing, and the answer is read from stored cc_hour_agg rows. The bytes-read
-- gap between this file and im01 IS the measured price of ragged edges.
SELECT
    range_start, range_end, peak, peak_minute, integral,
    round(avg_concurrent, 2) AS avg_concurrent,
    hours_from_hour_tier, change_points_from_minute_tier
FROM v_cc_window_range(
    p_start = {p_start:DateTime}, p_end = {p_end:DateTime},
    p_platform = '*', p_country = '*', p_content_id = -1)
