WITH
    150 AS GAP_S, 1 AS UNCLOSED_PAUSE_TO_RUN_END,
    per_session AS (
        SELECT video_session_id,
            arraySort(groupArray(toUnixTimestamp(event_timestamp))) AS ts,
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event = 'pause'))  AS pauses,
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event = 'resume')) AS resumes
        FROM ev_raw GROUP BY video_session_id
    ),
    runs AS (
        SELECT video_session_id, pauses, resumes,
            arrayJoin(arraySplit((t, i) -> (i > 1) AND ((t - ts[i - 1]) > GAP_S), ts, arrayEnumerate(ts))) AS run
        FROM per_session
    ),
    windowed AS (
        SELECT video_session_id, resumes, run[1] AS run_start, run[length(run)] AS run_end,
            arrayFilter(w -> w.2 > w.1, arraySort(arrayMap(
                p -> (p, least(
                        if(arrayFirst(x -> x >= p, resumes) = 0,
                           if(UNCLOSED_PAUSE_TO_RUN_END = 1, run[length(run)],
                              if(arrayFirst(x -> x > p, run) = 0, run[length(run)], arrayFirst(x -> x > p, run))),
                           arrayFirst(x -> x >= p, resumes)),
                        run[length(run)])),
                arrayFilter(p -> (p >= run[1]) AND (p < run[length(run)]), pauses)
            ))) AS wins
        FROM runs
    ),
    -- Count the INTERMEDIATE drops too: a pause window opening exactly at the
    -- cursor loses that one active instant inside the fold (`win.1 > acc.2`).
    folded AS (
        SELECT video_session_id, run_start, run_end, resumes,
            arrayFold((acc, win) -> (
                    toUInt32(acc.1 + if(win.1 = acc.2, 1, 0)),                 -- intermediate zero-length drops
                    greatest(acc.2, win.2)),
                wins, (toUInt32(0), toUInt32(run_start))) AS f
        FROM windowed
    )
SELECT sum(f.1) AS intermediate_zero_length_drops,
       uniqExactIf(video_session_id, f.1 > 0) AS sessions
FROM folded;
