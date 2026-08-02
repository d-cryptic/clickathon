-- ============================================================================
-- probe_state_gate.sql -- MEASUREMENT PROBE, not part of the model.
--
-- Re-derives active intervals from v_ev_model_input using the SAME algorithm as
-- sql/30_build_intervals.sql (arraySplit runs, pause-window complement,
-- TAIL_S on run ends, UNCLOSED_PAUSE_TO_RUN_END=1, POINT_ACTIVITY_COUNTS=0)
-- with ONE addition, selected by {bg_mode:UInt8}:
--
--   0  BASELINE  -- explicit AppBackgrounded is not a state gate. This is what
--                   ships. Must reproduce the deployed session_intervals.
--   1  GATED     -- AppBackgrounded opens a suppression window; it closes at the
--                   first AppForegrounded, `resume` or VideoPlay at/after it.
--   2  HARD      -- AppBackgrounded opens a suppression window; it closes ONLY
--                   at an explicit AppForegrounded.
--
-- In modes 1 and 2 an unclosed background window runs to run_end + 1, the same
-- conservative rule the model already applies to an unclosed pause.
--
-- Dimension attribution is deliberately omitted: `ts` drives run splitting and
-- is byte-identical to the model's, so attribution cannot move a boundary, only
-- label it. Peak and counted hours are therefore exact.
-- ============================================================================
INSERT INTO bg_state_gate.si
WITH
    150 AS GAP_S,
    60  AS TAIL_S,
    1   AS UNCLOSED_PAUSE_TO_RUN_END,
    0   AS POINT_ACTIVITY_COUNTS,
    per_session AS (
        SELECT
            video_session_id,
            arraySort(groupArray(toUnixTimestamp(event_timestamp))) AS ts,
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event = 'pause'))  AS pauses,
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event = 'resume')) AS resumes,
            -- the two explicit-state arrays
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event_type = 'AppBackgrounded')) AS bgs,
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp),
                {bg_mode:UInt8} IN (2, 3)
                    ? (event_type = 'AppForegrounded')
                    : (event_type IN ('AppForegrounded','VideoPlay') OR event = 'resume'))) AS fgs,
            countIf(event_type = 'VideoSessionEnd') = 0 AS is_open
        FROM codex_official_green_20260802_075132.v_ev_model_input
        GROUP BY video_session_id
    ),
    runs AS (
        SELECT
            video_session_id, is_open, pauses, resumes, bgs, fgs,
            arrayJoin(arraySplit((t, i) -> (i > 1) AND ((t - ts[i - 1]) > GAP_S), ts, arrayEnumerate(ts))) AS run
        FROM per_session
    ),
    windowed AS (
        SELECT
            video_session_id, is_open, bgs,
            run[1]           AS run_start,
            run[length(run)] AS run_end,
            arrayFilter(w -> w.2 > w.1, arraySort(arrayConcat(
                -- pause windows, exactly as the model builds them
                arrayMap(
                    p -> (p,
                            if((arrayFirst(x -> x >= p, resumes) != 0)
                                 AND (arrayFirst(x -> x >= p, resumes) <= run[length(run)]),
                               toUInt32(arrayFirst(x -> x >= p, resumes)),
                               if(UNCLOSED_PAUSE_TO_RUN_END = 1,
                                  toUInt32(run[length(run)] + 1),
                                  if(arrayFirst(x -> x > p, run) = 0,
                                     toUInt32(run[length(run)] + 1),
                                     toUInt32(arrayFirst(x -> x > p, run)))))),
                    arrayFilter(p -> (p >= run[1]) AND (p < run[length(run)]), pauses)
                ),
                -- background windows, same shape, only when the gate is on
                if({bg_mode:UInt8} IN (0, 4),
                   CAST([], 'Array(Tuple(UInt32, UInt32))'),
                   arrayMap(
                       b -> (b,
                               if((arrayFirst(x -> x >= b, fgs) != 0)
                                    AND (arrayFirst(x -> x >= b, fgs) <= run[length(run)]),
                                  toUInt32(arrayFirst(x -> x >= b, fgs)),
                                  toUInt32(run[length(run)] + 1))),
                       arrayFilter(b -> (b >= run[1]) AND (b < run[length(run)]), bgs)
                   ))
            ))) AS pause_windows
        FROM runs
    ),
    folded AS (
        SELECT
            *,
            arrayFold(
                (acc, win) -> (
                    if((win.1 > acc.2) OR ((POINT_ACTIVITY_COUNTS = 1) AND (win.1 = acc.2)),
                       arrayPushBack(acc.1, (acc.2, win.1)), acc.1),
                    greatest(acc.2, win.2)
                ),
                pause_windows,
                (CAST([], 'Array(Tuple(UInt32, UInt32))'), toUInt32(run_start))
            ) AS fold
        FROM windowed
    )
SELECT
    video_session_id,
    toDateTime64(seg.1, 3)                                  AS interval_start,
    toDateTime64(seg.2 + if(seg.2 = run_end
                            AND NOT (({bg_mode:UInt8} IN (3, 4)) AND has(bgs, run_end)),
                          TAIL_S, 0), 3) AS interval_end,
    is_open
FROM folded
ARRAY JOIN
    arrayFilter(x -> if(POINT_ACTIVITY_COUNTS = 1, x.2 >= x.1, x.2 > x.1),
        arrayPushBack(fold.1, (fold.2, toUInt32(run_end)))
    ) AS seg;
