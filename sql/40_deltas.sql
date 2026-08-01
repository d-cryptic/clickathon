-- ============================================================================
-- 40_deltas.sql — H3. session_intervals -> cc_minute_delta, hour-clipped.
--
-- Per ADR 0003, every interval is clipped to each hour it touches:
--   +1 at greatest(toStartOfMinute(s), H)
--   -1 at toStartOfMinute(e) + 1 minute, ONLY if the interval ends inside H
-- An interval surviving past H emits no close; hour H+1 re-opens it with a
-- fresh +1. Every hour's running sum is therefore absolute, so a range query
-- never scans from t=0 and partition pruning is exact rather than nominal.
--
-- EDGE CASE the ADR's rule does not state, handled here: if the interval ends
-- in the LAST minute of the hour, toStartOfMinute(e)+60 equals the next hour's
-- start, so the -1 would land in hour H+1 — which has no matching +1, and its
-- running sum would open at -1. The hour boundary already closes the interval,
-- so that close is simply not emitted.
--
-- Re-runnable: TRUNCATE first (see tools/build-model.sh). Deltas are additive,
-- so a double insert silently doubles every number — there is no dedup here to
-- save you.
-- ============================================================================

INSERT INTO cc_minute_delta

WITH
-- STEP 1 — merge each session's intervals at MINUTE granularity.
--
-- Without this the model double counts. A session that pauses and resumes
-- inside one minute produces two intervals that both touch that minute, and
-- emitting +1 per interval counts one viewer twice. Measured on the real file:
-- 7,395 (session, minute) pairs across 4,797 sessions — 44% of all sessions —
-- which is what /reconcile caught (556 of 1,903 minutes wrong, max diff 195).
--
-- Concurrency counts VIEWERS, not active fragments. Merging on
-- `next_start_minute <= last_end_minute + 60` is exactly equivalent in minute
-- coverage to keeping the fragments separate, and emits fewer rows.
--
-- This is an O(intervals) fold, NOT a per-minute expansion — the serving layer
-- stays O(intervals), which is the whole point of the delta model.
merged AS
(
    SELECT
        video_session_id,
        any(platform)   AS platform,
        any(country)    AS country,
        any(content_id) AS content_id,
        arrayFold(
            (acc, x) -> if(
                (length(acc.1) = 0) OR (x.1 > (acc.2 + 60)),
                -- disjoint at minute grain: start a new run
                (arrayPushBack(acc.1, x), x.2),
                -- touching or overlapping: extend the run in place
                (arrayConcat(
                    arraySlice(acc.1, 1, length(acc.1) - 1),
                    [(acc.1[length(acc.1)].1, greatest(acc.2, x.2))]
                 ), greatest(acc.2, x.2))
            ),
            arraySort(groupArray((
                toUInt32(toStartOfMinute(interval_start)),
                toUInt32(toStartOfMinute(interval_end))
            ))),
            (CAST([], 'Array(Tuple(UInt32, UInt32))'), toUInt32(0))
        ).1 AS runs
    FROM session_intervals FINAL
    GROUP BY video_session_id
),

-- STEP 2 — clip every merged run to each hour it touches (ADR 0003).
exploded AS
(
    SELECT
        platform,
        country,
        content_id,
        r.1 AS s,          -- already minute-truncated by the merge
        r.2 AS e,
        arrayJoin(range(
            toUInt32(intDiv(r.1, 3600) * 3600),
            toUInt32(intDiv(r.2, 3600) * 3600) + 1,
            3600
        )) AS h
    FROM merged
    ARRAY JOIN runs AS r
)

SELECT
    minute,
    platform,
    country,
    content_id,
    sum(d)  AS delta,
    sum(op) AS starts,
    sum(cl) AS ends
FROM
(
    -- OPEN: at the interval's own minute in its first hour, at the hour start
    -- in every subsequent hour.
    SELECT
        toDateTime(greatest(intDiv(s, 60) * 60, h)) AS minute,
        platform, country, content_id,
        toInt64(1)  AS d,
        toUInt64(1) AS op,
        toUInt64(0) AS cl
    FROM exploded

    UNION ALL

    -- CLOSE: only when the interval genuinely ends inside this hour AND the
    -- close minute is still inside it (see the edge case above).
    SELECT
        toDateTime((intDiv(e, 60) * 60) + 60) AS minute,
        platform, country, content_id,
        toInt64(-1) AS d,
        toUInt64(0) AS op,
        toUInt64(1) AS cl
    FROM exploded
    WHERE (e < (h + 3600))
      AND (((intDiv(e, 60) * 60) + 60) < (h + 3600))
)
GROUP BY minute, platform, country, content_id;
