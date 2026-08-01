-- im05 — INTERVAL, ragged range INSIDE one hour (10:17 -> 10:43), no filter.
-- Head hour and tail hour are the SAME hour; arrayDistinct in the view keeps it
-- from being scanned twice (double integral). The edge case ADR 0003 calls out.
SELECT
    range_start, range_end, peak, peak_minute, integral,
    round(avg_concurrent, 2) AS avg_concurrent,
    hours_from_hour_tier, change_points_from_minute_tier
FROM v_cc_window_range(
    p_start = {p_start:DateTime}, p_end = {p_end:DateTime},
    p_platform = '*', p_country = '*', p_content_id = -1)
