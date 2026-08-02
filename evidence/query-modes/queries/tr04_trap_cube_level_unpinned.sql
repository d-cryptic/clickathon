-- tr04 — THE CUBE-LEVEL TRAP at hour grain. The minute-tier version of this is
-- the documented "285 vs 1,837" trap; it has an hour-tier twin, and the hour-tier
-- one is worse because it has TWO distinct failure modes.
--
-- cc_hour_agg materialises all 8 subsets of (platform, country, content_id).
-- The levels OVERLAP by construction — every level covers the same viewers,
-- sliced differently — so:
--
--   MODE 1, no cube_level pinned: rows from all 8 levels come back at once.
--   sum(integral) is therefore EXACTLY 8x the truth. It looks like a big number
--   from a real table and there is nothing in the shape of the result to say so.
--
--   MODE 2, cube_level = 7 (full grain) with a bare max(peak): returns the peak
--   of the single busiest dimension COMBINATION, not the total. This is the
--   "peak is not summable across dimensions" rule (docs/CONVENTIONS.md) meeting
--   a point query, and it under-reports by roughly an order of magnitude.
--
-- The correct read pins BOTH the cube level and the dim equalities — which is
-- exactly what v_concurrency_hour_total does (cube_level = 0, dims all sentinel).
-- ORDER BY is not decoration here: a bare UNION ALL returns its branches in
-- whatever order the pipeline finishes them, and this query's three captured
-- runs produced two different row orders (identical rows, identical bytes read).
-- An evidence file whose committed answer changes between runs is not evidence.
SELECT trap, rows_returned, wrong_answer, correct_answer, inflation_factor
FROM
(
SELECT
    'mode 1 — no cube_level pinned' AS trap,
    count()       AS rows_returned,
    sum(integral) AS wrong_answer,
    (SELECT integral FROM v_concurrency_hour_total WHERE hour = {p_hour:DateTime}) AS correct_answer,
    round(sum(integral) / (SELECT integral FROM v_concurrency_hour_total WHERE hour = {p_hour:DateTime}), 3)
                  AS inflation_factor
FROM v_concurrency_hour
WHERE hour = {p_hour:DateTime}

UNION ALL

SELECT
    'mode 2 — cube_level=7, bare max(peak)' AS trap,
    count()    AS rows_returned,
    max(peak)  AS wrong_answer,
    (SELECT peak FROM v_concurrency_hour_total WHERE hour = {p_hour:DateTime}) AS correct_answer,
    round(max(peak) / (SELECT peak FROM v_concurrency_hour_total WHERE hour = {p_hour:DateTime}), 3)
               AS inflation_factor
FROM v_concurrency_hour
WHERE hour = {p_hour:DateTime} AND cube_level = 7
)
ORDER BY trap
