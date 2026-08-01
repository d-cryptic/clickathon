-- ============================================================================
-- 90_reconcile.sql — THE GATE. Recompute concurrency from ev_raw and compare
-- against the serving layer.
--
-- "Truth" here is derived from ev_raw ONLY. It never reads session_intervals or
-- cc_minute_delta, so it exercises the whole pipeline rather than agreeing with
-- itself.
--
-- It also uses a DIFFERENT implementation of the same spec: runs are detected
-- with window functions (lagInFrame + a running sum of run breaks) where
-- 30_build_intervals.sql uses arraySplit over a sorted array. An error in
-- either implementation shows up as a disagreement instead of cancelling out.
--
-- Any non-zero delta is a FAILURE. Run via tools/reconcile.sh.
-- ============================================================================

WITH
    150 AS GAP_S,
    60  AS TAIL_S,

    -- The five minutes under test: peak, both data boundaries, two arbitrary.
    targets AS
    (
        SELECT arrayJoin([
            toDateTime('2026-07-26 10:56:00'),   -- global peak
            toDateTime('2026-07-14 15:43:00'),   -- first minute of data
            toDateTime('2026-07-26 11:31:00'),   -- last minute of data
            toDateTime('2026-07-26 11:10:00'),
            toDateTime('2026-07-26 06:09:00')
        ]) AS m
    ),

    -- Run detection, window-function flavour.
    --
    -- DISTINCT first, deliberately. The raw file contains duplicate events at
    -- identical timestamps, and run detection depends only on the SET of
    -- timestamps. Without the dedup, `prev_ts`/`rn` (ordered by the millisecond
    -- event_timestamp) and the running sum (ordered by the second-truncated ts)
    -- resolve ties in different orders, so run boundaries land in the wrong
    -- places. That produced a false FAIL: 8 sessions counted as active across a
    -- 381-second heartbeat gap they had clearly stopped watching during.
    distinct_ts AS
    (
        SELECT DISTINCT video_session_id, toUInt32(event_timestamp) AS ts
        FROM ev_raw
    ),
    numbered AS
    (
        SELECT
            video_session_id,
            ts,
            lagInFrame(ts)   OVER (PARTITION BY video_session_id ORDER BY ts) AS prev_ts,
            row_number()     OVER (PARTITION BY video_session_id ORDER BY ts) AS rn
        FROM distinct_ts
    ),
    runs_marked AS
    (
        SELECT
            video_session_id,
            ts,
            sum(if((rn = 1) OR ((ts - prev_ts) > GAP_S), 1, 0)) OVER (
                PARTITION BY video_session_id ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS run_id
        FROM numbered
    ),
    runs AS
    (
        SELECT video_session_id, run_id, min(ts) AS r_start, max(ts) AS r_end
        FROM runs_marked
        GROUP BY video_session_id, run_id
    ),

    pauses AS
    (
        SELECT
            video_session_id,
            arraySort(groupArrayIf(toUInt32(event_timestamp), event = 'pause'))  AS ps,
            arraySort(groupArrayIf(toUInt32(event_timestamp), event = 'resume')) AS rs
        FROM ev_raw
        GROUP BY video_session_id
    ),

    -- Paused windows clipped into each run; an unclosed pause runs to the run
    -- end (the conservative rule, ADR 0007).
    windowed AS
    (
        SELECT
            r.video_session_id AS video_session_id,
            r.r_start          AS r_start,
            r.r_end            AS r_end,
            arraySort(arrayMap(
                p -> (p, least(if(arrayFirst(x -> x > p, p2.rs) = 0, r.r_end, arrayFirst(x -> x > p, p2.rs)), r.r_end)),
                arrayFilter(p -> (p >= r.r_start) AND (p < r.r_end), p2.ps)
            )) AS wins
        FROM runs AS r
        LEFT JOIN pauses AS p2 ON p2.video_session_id = r.video_session_id
    ),

    -- Active segments = complement of the paused windows inside the run.
    folded AS
    (
        SELECT
            video_session_id,
            r_start,
            r_end,
            arrayFold(
                (acc, w) -> (
                    if(w.1 > acc.2, arrayPushBack(acc.1, (acc.2, w.1)), acc.1),
                    greatest(acc.2, w.2)
                ),
                wins,
                (CAST([], 'Array(Tuple(UInt32, UInt32))'), toUInt32(r_start))
            ) AS f
        FROM windowed
    ),

    -- One row per active segment, with tail grace ONLY on the segment that ends
    -- at the run end (a pause-ended segment gets none — we know when it stopped).
    segments AS
    (
        SELECT
            video_session_id,
            seg.1 AS a,
            seg.2 + if(seg.2 = r_end, TAIL_S, 0) AS b
        FROM folded
        ARRAY JOIN arrayFilter(x -> x.2 > x.1, arrayPushBack(f.1, (f.2, toUInt32(r_end)))) AS seg
    ),

    -- A session counts in minute M iff a segment's minute range covers M —
    -- the same semantic the delta model encodes as +1 at start-minute and
    -- -1 at end-minute + 1.
    truth AS
    (
        SELECT t.m AS minute, uniqExact(s.video_session_id) AS truth
        FROM targets AS t
        CROSS JOIN segments AS s
        WHERE (intDiv(s.a, 60) * 60 <= toUInt32(t.m)) AND (intDiv(s.b, 60) * 60 >= toUInt32(t.m))
        GROUP BY t.m
    ),

    -- The serving layer: running sum of hour-clipped deltas up to M, within M's hour.
    served AS
    (
        -- CROSS JOIN + WHERE, not JOIN ON: ClickHouse rejects a range predicate
        -- as a join key (Code: 403, cannot determine join keys).
        SELECT t.m AS minute, toInt64(sum(d.delta)) AS served
        FROM targets AS t
        CROSS JOIN cc_minute_delta AS d
        WHERE (d.minute >= toStartOfHour(t.m)) AND (d.minute <= t.m)
        GROUP BY t.m
    )

SELECT
    t.minute                                AS minute,
    t.truth                                 AS truth_from_ev_raw,
    ifNull(s.served, 0)                     AS served_from_delta,
    ifNull(s.served, 0) - t.truth           AS delta,
    if(ifNull(s.served, 0) = t.truth, 'PASS', 'MISMATCH') AS verdict
FROM truth AS t
LEFT JOIN served AS s ON s.minute = t.minute
ORDER BY minute;
