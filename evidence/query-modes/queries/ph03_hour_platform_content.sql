-- ph03 — POINT-IN-TIME, hour grain, multi-dimension (platform AND content_id).
-- Cube level 5 (bits: platform=1, content=4). The cube stores a separately
-- computed curve per level, so this is a stored row, not a derivation.
SELECT hour, platform, content_id, peak, peak_minute, integral, round(avg_concurrent, 2) AS avg_concurrent
FROM v_concurrency_hour
WHERE cube_level = 5
  AND platform = {p_platform:String} AND country = '*' AND content_id = {p_content_id:Int64}
  AND hour = {p_hour:DateTime}
