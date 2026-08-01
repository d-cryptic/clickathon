-- ============================================================================
-- evidence/schema-drift/worked-example.sql — a BRAND-NEW dimension, filterable
-- the day it arrives (ADR 0024). Run against a scratch db that loaded a file
-- carrying an unforeseen `device_type` column: the loader put it in
-- ev_raw.extra, and this query filters concurrency on extra['device_type']
-- with NO schema change and NO model change.
--
-- Built-in correctness check: the probe file derives device_type from platform
-- (ANDROID_PHONE/IPHONE -> mobile, ANDROID_TAB -> tablet, Mweb -> web,
-- * _TV -> tv), so the per-minute series filtered on extra['device_type']='tv'
-- must EQUAL the series filtered on the five TV platforms. The SUMMARY row
-- asserts that on every minute of the day.
--
-- Counting rules are the shipped spec, same constants as
-- sql/30_build_intervals.sql / sql/90_reconcile.sql: runs split on a >150 s
-- gap, pause windows subtracted (resume lookup with >=, ADR 0009; unclosed
-- pause runs to run end), 60 s tail grace only where the run ends in silence.
-- ============================================================================

WITH
    150 AS GAP_S,
    60  AS TAIL_S,
    1   AS UNCLOSED_PAUSE_TO_RUN_END,

    -- One dimension row per session, picked DETERMINISTICALLY: the modal
    -- (platform, device_type) pair, ties broken by value — the ADR 0009
    -- attribution rule. anyLast() here made the per-device peaks drift by a
    -- few viewers between runs (sessions do carry conflicting values), and
    -- picking the two columns independently could split a session's platform
    -- from its device class; the PAIR keeps them row-consistent, which is what
    -- makes the platform cross-check below exact.
    sess_dim AS
    (
        SELECT
            video_session_id,
            arraySort(v -> (-toInt64(countEqual(pairs, v)), v), arrayDistinct(pairs))[1] AS pick,
            pick.1 AS platform,
            pick.2 AS device_type
        FROM
        (
            SELECT video_session_id,
                   groupArray((platform, extra['device_type'])) AS pairs
            FROM ev_raw
            GROUP BY video_session_id
        )
    ),

    -- ------------------------------------------------------- active segments --
    -- Identical derivation to the truth side of sql/90_reconcile.sql.
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
            SELECT
                video_session_id, ts,
                sum(if((rn = 1) OR ((ts - prev_ts) > GAP_S), 1, 0)) OVER (
                    PARTITION BY video_session_id ORDER BY ts
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                ) AS run_id
            FROM numbered
        )
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
    windowed AS
    (
        SELECT
            r.video_session_id AS video_session_id,
            r.r_start AS r_start,
            r.r_end   AS r_end,
            arrayFilter(w -> w.2 > w.1, arraySort(arrayMap(
                p -> (p, least(
                        if(arrayFirst(x -> x >= p, p2.rs) = 0,
                           if(UNCLOSED_PAUSE_TO_RUN_END = 1,
                              r.r_end,
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
        SELECT
            video_session_id, r_start, r_end,
            arrayFold(
                (acc, w) -> (if(w.1 > acc.2, arrayPushBack(acc.1, (acc.2, w.1)), acc.1), greatest(acc.2, w.2)),
                wins,
                (CAST([], 'Array(Tuple(UInt32, UInt32))'), toUInt32(r_start))
            ) AS f
        FROM windowed
    ),
    segments AS
    (
        SELECT
            video_session_id,
            seg.1 AS a,
            seg.2 + if(seg.2 = r_end, TAIL_S, 0) AS b
        FROM folded
        ARRAY JOIN arrayFilter(x -> x.2 > x.1, arrayPushBack(f.1, (f.2, toUInt32(r_end)))) AS seg
    ),

    -- --------------------------- per-minute series, filtered both ways at once --
    minute_cc AS
    (
        SELECT
            toDateTime(m) AS minute,
            uniqExactIf(e.video_session_id, d.device_type = 'tv') AS cc_via_new_dim,
            uniqExactIf(e.video_session_id, d.platform IN
                ('SONY_ANDROID_TV', 'JIO_ANDROID_TV', 'XIAOMI_ANDROID_TV',
                 'SAMSUNG_HTML_TV', 'FIRE_TV', 'LG_HTML_TV'))     AS cc_via_platform
        FROM
        (
            SELECT video_session_id,
                   arrayJoin(range(intDiv(a, 60) * 60, (intDiv(b, 60) * 60) + 1, 60)) AS m
            FROM segments
        ) AS e
        INNER JOIN sess_dim AS d ON d.video_session_id = e.video_session_id
        GROUP BY minute
    )

SELECT * FROM
(
    -- 1 — the assertion: the new-dimension filter and the platform filter agree
    --     on every minute, or this run is evidence of nothing.
    SELECT
        0 AS ord,
        'SUMMARY' AS scope,
        concat('minutes_compared=', toString(count()))                          AS c1,
        concat('mismatched=',       toString(countIf(cc_via_new_dim != cc_via_platform))) AS c2,
        concat('peak_tv=',          toString(max(cc_via_new_dim)))              AS c3,
        if(countIf(cc_via_new_dim != cc_via_platform) = 0, 'PASS', 'MISMATCH')  AS verdict
    FROM minute_cc

    UNION ALL

    -- 2 — peak + time-weighted average per NEW-dimension value (minute grain,
    --     so mean of per-minute values equals the time-weighted average).
    SELECT 1, 'per-device', dt, concat('peak=', toString(peak)),
           concat('avg=', toString(round(avg_cc, 1))), ''
    FROM
    (
        SELECT
            device_type AS dt,
            max(cc)     AS peak,
            avg(cc)     AS avg_cc
        FROM
        (
            SELECT
                toDateTime(m)                 AS minute,
                d2.device_type                AS device_type,
                uniqExact(e.video_session_id) AS cc
            FROM
            (
                SELECT video_session_id,
                       arrayJoin(range(intDiv(a, 60) * 60, (intDiv(b, 60) * 60) + 1, 60)) AS m
                FROM segments
            ) AS e
            INNER JOIN sess_dim AS d2 ON d2.video_session_id = e.video_session_id
            GROUP BY minute, device_type
        ) AS per_min
        GROUP BY device_type
    )
)
ORDER BY ord, c1;
