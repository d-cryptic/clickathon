-- tr01 — THE TRAP, measured. A naive point lookup against a DIMENSIONED view:
--   SELECT max(concurrent) ... WHERE minute = <peak minute>
-- returns the peak of a single dimension COMBINATION, not the total — it looks
-- exactly like an answer and is wrong by an order of magnitude. rows_returned
-- shows why: one row per combination active that minute.
SELECT
    count()          AS rows_returned,
    max(concurrent)  AS looks_like_an_answer_but_is_one_combination
FROM v_concurrency_minute
WHERE minute = {p_minute:DateTime}
