-- ph02 — POINT-IN-TIME, hour grain, one dimension (platform).
-- Pin the cube level AND the dim equalities (ADR 0022): cube_level=1 selects
-- "platform real, country and content rolled up"; the dim equalities keep the
-- read on the sort-key prefix.
SELECT hour, platform, peak, peak_minute, integral, round(avg_concurrent, 2) AS avg_concurrent
FROM v_concurrency_hour
WHERE cube_level = 1
  AND platform = {p_platform:String} AND country = '*' AND content_id = -1
  AND hour = {p_hour:DateTime}
