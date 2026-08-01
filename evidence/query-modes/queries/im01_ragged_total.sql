-- im01 — INTERVAL, ragged range (10:17 -> 11:31), no filter. b11's shape,
-- re-measured on this scratch build so ragged and aligned twins share a baseline.
-- Both edges are mid-hour: 2 partial-hour minute scans + 0 whole hours... no —
-- 10:17->11:31 has ZERO whole hours ([11:00,11:00) empty is false: whole_lo=11:00,
-- whole_hi=11:00 -> empty) so BOTH hours go through the minute tier.
SELECT
    range_start, range_end, peak, peak_minute, integral,
    round(avg_concurrent, 2) AS avg_concurrent,
    hours_from_hour_tier, change_points_from_minute_tier
FROM v_cc_window_range(
    p_start = {p_start:DateTime}, p_end = {p_end:DateTime},
    p_platform = '*', p_country = '*', p_content_id = -1)
