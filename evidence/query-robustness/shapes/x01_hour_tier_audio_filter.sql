-- x01 — filter the HOUR tier by a dimension it does not carry (audio_language).
-- The hour cube stores platform/country/content only; the only defensible
-- behaviours are a loud error or a visible fallback. A silent unfiltered
-- answer would be the worst outcome. Expected: Code 47 (unknown identifier).
SELECT hour, peak
FROM v_concurrency_hour
WHERE audio_language = {p_audio:String}
ORDER BY hour
