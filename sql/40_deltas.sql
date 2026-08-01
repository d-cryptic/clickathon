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
--
-- SEVEN DIMENSIONS (ADR 0008). content_id/platform/country used to be the only
-- ones that survived; app_version, audio_language, subtitle_language and
-- player_version now come through too, and title/video_type/category ride free
-- off content_id via dict_content (80_content.sql). Two consequences worth
-- knowing before reading the code:
--
--   * ROW COUNT. Finer grain means more rows, MEASURED 24,951 -> 28,024 (1.12x).
--     It is bounded: this table holds at most one open and one close row per
--     (merged run, hour), so 36,930 rows on this file is the ceiling for ANY
--     number of dimensions. Adding a dimension can only spread rows out inside
--     that ceiling, never multiply past it. This is the property that makes
--     "should work even if the number of dimensions increases" true rather than
--     hopeful, and it is the whole reason the serving layer is deltas and not a
--     per-minute explosion.
--
--   * WHERE THE DIMS ARE ATTACHED. Per MERGED RUN, carried through the
--     arrayFold below — not per session with any(). The merge exists to stop one
--     viewer emitting two +1s in the same minute, so the dimension tuple has to
--     be constant within a merged run or the double count comes straight back.
--     Runs of the same session are minute-disjoint by construction, so different
--     runs MAY carry different tuples: a viewer who switches audio track between
--     two watch bursts is attributed correctly to both.
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
--
-- The fold tuple carries the four new dimensions in slots .3-.6. The MERGE
-- PREDICATE and the start/end arithmetic read only .1 and .2 and are byte
-- identical to the three-dimension version, so run boundaries — and therefore
-- every concurrency number — provably cannot move; the tuple only gains labels.
-- When two intervals merge, the run KEEPS THE EARLIER INTERVAL'S dimensions
-- (acc's, not x's): a merged run is one continuous viewing burst and it is
-- attributed to what the viewer was watching when the burst opened. Measured
-- exposure is in ADR 0008.
--
-- toString() on the dimension columns is not cosmetic: groupArray preserves
-- LowCardinality, and arrayFold requires the accumulator's element type to match
-- the source array's exactly, so an Array(Tuple(..., LowCardinality(String)))
-- source against a CAST-ed Array(Tuple(..., String)) accumulator does not
-- type-check.
--
-- platform / country / content_id keep any(). They are NOT part of this change:
-- 0 sessions carry two content_ids and 95 carry two platforms, and moving those
-- to a different rule would move numbers this task is not allowed to move. The
-- non-determinism of any() on them is real and is written up in ADR 0008 as a
-- separate, owner-facing decision — it shifts the user peak 2,815 -> 2,816.
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
                -- touching or overlapping: extend the run in place, keeping the
                -- run's own start and its own dimension tuple
                (arrayConcat(
                    arraySlice(acc.1, 1, length(acc.1) - 1),
                    [(acc.1[length(acc.1)].1,
                      greatest(acc.2, x.2),
                      acc.1[length(acc.1)].3,
                      acc.1[length(acc.1)].4,
                      acc.1[length(acc.1)].5,
                      acc.1[length(acc.1)].6)]
                 ), greatest(acc.2, x.2))
            ),
            arraySort(groupArray((
                toUInt32(toStartOfMinute(interval_start)),
                toUInt32(toStartOfMinute(interval_end)),
                toString(app_version),
                toString(audio_language),
                toString(subtitle_language),
                toString(player_version)
            ))),
            (CAST([], 'Array(Tuple(UInt32, UInt32, String, String, String, String))'), toUInt32(0))
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
        r.3 AS app_version,
        r.4 AS audio_language,
        r.5 AS subtitle_language,
        r.6 AS player_version,
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
    subtitle_language,
    player_version,
    audio_language,
    app_version,
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
        subtitle_language, player_version, audio_language, app_version,
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
        subtitle_language, player_version, audio_language, app_version,
        toInt64(-1) AS d,
        toUInt64(0) AS op,
        toUInt64(1) AS cl
    FROM exploded
    WHERE (e < (h + 3600))
      AND (((intDiv(e, 60) * 60) + 60) < (h + 3600))
)
GROUP BY minute, platform, country, content_id,
         subtitle_language, player_version, audio_language, app_version;
