-- b13 — top-10 content by peak concurrency inside the peak hour, with metadata.
-- Statement shape: content-level concurrency ("understand demand by title or content
-- identifier") at hour grain.
-- Serving path: the content cube level ('*','*',content_id) of cc_hour_agg — stored
-- peaks, no recomputation — enriched at query time via dict_content (dictGet, never a
-- denormalised copy). NOTE: title is a decoration here, not a key; content_id is.
SELECT
    content_id,
    dictGet('dict_content', 'title',      tuple(content_id)) AS title,
    dictGet('dict_content', 'video_type', tuple(content_id)) AS video_type,
    peak,
    peak_minute,
    round(integral / 3600, 1) AS avg_concurrent
FROM v_concurrency_hour
WHERE platform = '*'
  AND country = '*'
  AND content_id != -1
  AND hour = {p_hour:DateTime}
ORDER BY peak DESC, content_id ASC
LIMIT 10
