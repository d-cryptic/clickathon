-- pd03 — POINT-IN-TIME, day grain, multi-dimension (platform AND content_id). Cube level 5.
SELECT day, platform, content_id, peak, peak_minute, integral, round(avg_concurrent, 2) AS avg_concurrent, active_hours
FROM v_concurrency_day
WHERE cube_level = 5
  AND platform = {p_platform:String} AND country = '*' AND content_id = {p_content_id:Int64}
  AND day = {p_day:Date}
