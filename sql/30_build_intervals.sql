-- ============================================================================
-- 30_build_intervals.sql — H2. Derive session_intervals from the raw stream.
--
-- ACTIVE = (a run of events with no gap > HEARTBEAT_GAP_S) MINUS (paused windows).
--
-- Two signals, because ONE is not enough — measured, see ADR 0007:
--
--   backgrounding -> heartbeat GAPS. Beats effectively stop while backgrounded
--                    (0.047/min vs 4.72/min active, a 100x drop), so a gap
--                    detects it. bg/fg events are NOT used: they do not pair
--                    (14,700 vs 14,321) — ADR 0001.
--
--   pause         -> EXPLICIT pause/resume events. Beats SURVIVE a pause
--                    (0.756/min, 16% of active = one event every ~79s, well
--                    inside a 150s threshold). A gap-only model therefore
--                    counts paused time as watching, which the statement
--                    forbids. This is the correction ADR 0007 mandates.
--
-- Re-running is safe: session_intervals is a ReplacingMergeTree keyed on
-- (video_session_id, interval_start) with interval_end as the version, so a
-- rebuild replaces rather than duplicates, and a late heartbeat EXTENDS an
-- interval instead of adding one.
-- ============================================================================

INSERT INTO session_intervals
WITH
    -- Tunables. GAP_S is now derived from the MEASURED inter-arrival p99 of 49s
    -- (ADR 0007), not from the "60s cadence" that the data disproved. 150s is
    -- ~3x p99 — wide enough to survive a burst pause, tight enough to catch a
    -- backgrounding within one minute bucket.
    150 AS GAP_S,
    -- Credit after the last event of a run. One cadence, not a full gap: the
    -- viewer was watching until at least the next expected event.
    60  AS TAIL_S,

    per_session AS (
        SELECT
            video_session_id,
            -- A session is almost always one user/content/platform: 1 session
            -- has 2 content_ids, 95 have 2 platforms, 120 have 2 user_ids out
            -- of 10,866. any() is accurate for 98.8% and the alternative
            -- (splitting intervals per dimension change) is not worth it until
            -- something measures it as mattering.
            any(user_id)    AS user_id,
            any(content_id) AS content_id,
            any(platform)   AS platform,
            any(country)    AS country,
            arraySort(groupArray(toUnixTimestamp(event_timestamp)))                    AS ts,
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event = 'pause'))  AS pauses,
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event = 'resume')) AS resumes,
            -- No VideoSessionEnd at build time => still open. 2.2% of sessions
            -- emit events up to 2,081s AFTER their end event (ADR 0007), so
            -- "ended" is not the same as "sealed".
            countIf(event_type = 'VideoSessionEnd') = 0 AS is_open
        FROM ev_raw
        GROUP BY video_session_id
    ),

    -- Split the session into runs wherever the gap exceeds the threshold.
    runs AS (
        SELECT
            video_session_id, user_id, content_id, platform, country, is_open,
            pauses, resumes,
            arrayJoin(arraySplit((t, i) -> (i > 1) AND ((t - ts[i - 1]) > GAP_S), ts, arrayEnumerate(ts))) AS run
        FROM per_session
    ),

    -- Clip pause windows into the run. An unclosed pause (23% of them) runs to
    -- the end of its run: CONSERVATIVE, never credit time we cannot prove was
    -- active. ADR 0007 records the alternative and what it costs.
    windowed AS (
        SELECT
            video_session_id, user_id, content_id, platform, country, is_open,
            run[1]              AS run_start,
            run[length(run)]    AS run_end,
            arraySort(arrayMap(
                p -> (p, least(if(arrayFirst(x -> x > p, resumes) = 0, run[length(run)], arrayFirst(x -> x > p, resumes)),
                               run[length(run)])),
                arrayFilter(p -> (p >= run[1]) AND (p < run[length(run)]), pauses)
            )) AS pause_windows
        FROM runs
    ),

    -- Complement of the merged pause windows within [run_start, run_end].
    -- arrayFold walks the sorted windows carrying (segments_so_far, cursor).
    folded AS (
        SELECT
            *,
            arrayFold(
                (acc, win) -> (
                    if(win.1 > acc.2, arrayPushBack(acc.1, (acc.2, win.1)), acc.1),
                    greatest(acc.2, win.2)
                ),
                pause_windows,
                (CAST([], 'Array(Tuple(UInt32, UInt32))'), toUInt32(run_start))
            ) AS fold
        FROM windowed
    )

SELECT
    video_session_id,
    user_id,
    content_id,
    platform,
    country,
    toDateTime64(seg.1, 3)                     AS interval_start,
    -- Tail grace is ONLY for a segment that ends because the run ended — there
    -- we do not know when the viewer actually left, so we credit one cadence.
    -- A segment ending at a PAUSE gets none: we know to the second when they
    -- stopped watching, and crediting 60s past it books paused (often
    -- backgrounded) time as watch time. Measured on the worked example: the
    -- viewer paused at 11:04:29 and backgrounded at 11:04:31, so the tail was
    -- landing entirely inside a 24-minute background.
    toDateTime64(seg.2 + if(seg.2 = run_end, TAIL_S, 0), 3) AS interval_end,
    is_open
FROM folded
ARRAY JOIN
    arrayFilter(x -> x.2 > x.1,
        arrayPushBack(fold.1, (fold.2, toUInt32(run_end)))
    ) AS seg;
