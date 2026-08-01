-- ============================================================================
-- evidence/schema-drift/raw-fallback-network.sql — the RAW-RECOMPUTE fallback
-- for a new dimension that is NOT a function of any delta-tier key (ADR 0024).
-- network_type is session-level and independent of (platform, country,
-- content_id), so the tier cannot serve it at any grain; this query derives
-- active segments from ev_raw (same spec constants as sql/30_build_intervals /
-- sql/90_reconcile) for the sessions matching extra['network_type'] = 'wifi'.
-- Measured on the full 905,558-row file: see ../schema-drift/probes.txt.
-- ============================================================================
WITH 150 AS GAP_S, 60 AS TAIL_S, 1 AS UNCLOSED_PAUSE_TO_RUN_END,
wifi_sessions AS
(
    SELECT video_session_id FROM ev_raw GROUP BY video_session_id
    HAVING anyLast(extra['network_type']) = 'wifi'
),
distinct_ts AS
(
    SELECT DISTINCT video_session_id, toUInt32(event_timestamp) AS ts
    FROM ev_raw WHERE video_session_id IN (SELECT video_session_id FROM wifi_sessions)
),
numbered AS
(
    SELECT video_session_id, ts,
           lagInFrame(ts) OVER (PARTITION BY video_session_id ORDER BY ts) AS prev_ts,
           row_number()   OVER (PARTITION BY video_session_id ORDER BY ts) AS rn
    FROM distinct_ts
),
runs AS
(
    SELECT video_session_id, run_id, min(ts) AS r_start, max(ts) AS r_end,
           arraySort(groupArray(ts)) AS run_ts
    FROM
    (
        SELECT video_session_id, ts,
               sum(if((rn = 1) OR ((ts - prev_ts) > GAP_S), 1, 0)) OVER (
                   PARTITION BY video_session_id ORDER BY ts
                   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS run_id
        FROM numbered
    )
    GROUP BY video_session_id, run_id
),
pauses AS
(
    SELECT video_session_id,
           arraySort(groupArrayIf(toUInt32(event_timestamp), event = 'pause'))  AS ps,
           arraySort(groupArrayIf(toUInt32(event_timestamp), event = 'resume')) AS rs
    FROM ev_raw WHERE video_session_id IN (SELECT video_session_id FROM wifi_sessions)
    GROUP BY video_session_id
),
windowed AS
(
    SELECT r.video_session_id AS video_session_id, r.r_start AS r_start, r.r_end AS r_end,
           arrayFilter(w -> w.2 > w.1, arraySort(arrayMap(
               p -> (p, least(
                       if(arrayFirst(x -> x >= p, p2.rs) = 0,
                          if(UNCLOSED_PAUSE_TO_RUN_END = 1, r.r_end,
                             if(arrayFirst(x -> x > p, r.run_ts) = 0, r.r_end, arrayFirst(x -> x > p, r.run_ts))),
                          arrayFirst(x -> x >= p, p2.rs)),
                       r.r_end)),
               arrayFilter(p -> (p >= r.r_start) AND (p < r.r_end), p2.ps)
           ))) AS wins
    FROM runs AS r
    LEFT JOIN pauses AS p2 ON p2.video_session_id = r.video_session_id
),
folded AS
(
    SELECT video_session_id, r_start, r_end,
           arrayFold((acc, w) -> (if(w.1 > acc.2, arrayPushBack(acc.1, (acc.2, w.1)), acc.1), greatest(acc.2, w.2)),
                     wins, (CAST([], 'Array(Tuple(UInt32, UInt32))'), toUInt32(r_start))) AS f
    FROM windowed
),
segments AS
(
    SELECT video_session_id, seg.1 AS a, seg.2 + if(seg.2 = r_end, TAIL_S, 0) AS b
    FROM folded
    ARRAY JOIN arrayFilter(x -> x.2 > x.1, arrayPushBack(f.1, (f.2, toUInt32(r_end)))) AS seg
)
SELECT max(cc) AS peak_wifi, count() AS active_minutes
FROM
(
    SELECT toDateTime(m) AS minute, uniqExact(video_session_id) AS cc
    FROM (SELECT video_session_id, arrayJoin(range(intDiv(a, 60) * 60, (intDiv(b, 60) * 60) + 1, 60)) AS m FROM segments)
    GROUP BY minute
);
