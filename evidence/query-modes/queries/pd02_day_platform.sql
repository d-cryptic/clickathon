-- pd02 — POINT-IN-TIME, day grain, one dimension (platform). Cube level 1.
SELECT day, platform, peak, peak_minute, integral, round(avg_concurrent, 2) AS avg_concurrent, active_hours
FROM v_concurrency_day
WHERE cube_level = 1
  AND platform = {p_platform:String} AND country = '*' AND content_id = -1
  AND day = {p_day:Date}
