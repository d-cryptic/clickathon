-- FAIL-CLOSED variant of sql/30_build_intervals.sql (Q28 measurement, scratch only).
-- A second counts only while BOTH state gates are open, and liveness comes only
-- from playback telemetry. Rules, stated exactly:
--   1. Liveness (run membership/splitting): event_type IN ('VideoHeartbeat','VideoPlay').
--      Everything else is recorded but never renews a run.
--   2. Playing gate: opens at VideoPlay or `resume`, closes at `pause` or
--      VideoSessionEnd. Time before the first play of a run (state carried in
--      from before the run) is excluded. Unclosed pause: to run end (shipped rule).
--   3. Foreground gate: closes at AppBackgrounded, reopens at AppForegrounded.
--      Unclosed background: to run end (fail-closed). State carried across runs.
--   4. VideoSessionEnd is terminal for its run: everything from the end event to
--      the run end is excluded (post-end events still in the file do not count).
--   5. Tail: only when the run ends in silence, capped at the next explicit
--      stop event (pause/end/background) if one follows within TAIL_S.
INSERT INTO session_intervals
    (video_session_id, user_id, content_id, platform, country,
     app_version, audio_language, subtitle_language, player_version,
     interval_start, interval_end, is_open, build_version)
WITH
    150 AS GAP_S,
    60  AS TAIL_S,
    1 AS UNCLOSED_PAUSE_TO_RUN_END,

    per_session AS (
        SELECT
            video_session_id,
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp),
                      event_type IN ('VideoHeartbeat','VideoPlay')))                    AS ts,
            arraySort(groupArray((
                toUnixTimestamp(event_timestamp),
                app_version, audio_language, subtitle_language, player_version,
                user_id, content_id, platform, country
            ))) AS dim_events,
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event = 'pause'))  AS pauses,
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event = 'resume')) AS resumes,
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp),
                      event_type = 'VideoPlay' OR event = 'resume'))                    AS plays,
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp),
                      event_type = 'AppBackgrounded'))                                  AS bgs,
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp),
                      event_type = 'AppForegrounded'))                                  AS fgs,
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp),
                      event_type = 'VideoSessionEnd'))                                  AS ends,
            countIf(event_type = 'VideoSessionEnd') = 0 AS is_open
        FROM ev_raw
        GROUP BY video_session_id
    ),

    runs AS (
        SELECT
            video_session_id, is_open,
            pauses, resumes, plays, bgs, fgs, ends, dim_events,
            arrayJoin(arraySplit((t, i) -> (i > 1) AND ((t - ts[i - 1]) > GAP_S), ts, arrayEnumerate(ts))) AS run
        FROM per_session
    ),

    windowed AS (
        SELECT
            video_session_id, is_open,
            dim_events,
            run[1]              AS run_start,
            run[length(run)]    AS run_end,
            -- playing/foreground state carried in from before the run
            arraySort(arrayConcat(pauses, ends)) AS stop_evs,
            (arrayLast(x -> x <= run_start, plays) > 0)
              AND (arrayLast(x -> x <= run_start, plays)
                   >= arrayLast(x -> x <= run_start, stop_evs))         AS playing_at_start,
            (arrayLast(x -> x < run_start, bgs) = 0)
              OR (arrayLast(x -> x < run_start, fgs)
                  >= arrayLast(x -> x < run_start, bgs))                AS fg_at_start,
            -- fail-closed tail: only into silence, capped at the next stop event
            arrayFirst(x -> x >= run_end, arraySort(arrayConcat(pauses, ends, bgs))) AS next_stop,
            if(next_stop = 0, TAIL_S,
               least(TAIL_S, if(next_stop > run_end, next_stop - run_end, 0)))        AS tail_fc,
            arrayFilter(w -> w.2 > w.1, arraySort(arrayConcat(
                -- shipped pause windows (conservative unclosed rule, >= resume lookup)
                arrayMap(
                    p -> (p, least(
                            if(arrayFirst(x -> x >= p, resumes) = 0,
                               if(UNCLOSED_PAUSE_TO_RUN_END = 1,
                                  run[length(run)],
                                  if(arrayFirst(x -> x > p, run) = 0, run[length(run)], arrayFirst(x -> x > p, run))),
                               arrayFirst(x -> x >= p, resumes)),
                            run[length(run)])),
                    arrayFilter(p -> (p >= run[1]) AND (p < run[length(run)]), pauses)
                ),
                -- background windows: bg -> next fg, unclosed -> run end (fail-closed)
                arrayMap(
                    b -> (b, if(arrayFirst(x -> x >= b, fgs) = 0,
                                toUInt32(run[length(run)]),
                                least(arrayFirst(x -> x >= b, fgs), toUInt32(run[length(run)])))),
                    arrayFilter(b -> (b >= run[1]) AND (b < run[length(run)]), bgs)
                ),
                -- terminal end: from the first end event inside the run to run end
                arrayMap(
                    e2 -> (e2, toUInt32(run[length(run)])),
                    arrayFilter(e2 -> (e2 >= run[1]) AND (e2 < run[length(run)]), ends)
                ),
                -- not playing at run start: excluded until the first play/resume in the run
                if(playing_at_start, CAST([], 'Array(Tuple(UInt32, UInt32))'),
                   [(toUInt32(run[1]),
                     if(arrayFirst(x -> x > run[1], plays) = 0,
                        toUInt32(run[length(run)]),
                        least(arrayFirst(x -> x > run[1], plays), toUInt32(run[length(run)]))))]),
                -- backgrounded at run start: excluded until the first foreground in the run
                if(fg_at_start, CAST([], 'Array(Tuple(UInt32, UInt32))'),
                   [(toUInt32(run[1]),
                     if(arrayFirst(x -> x > run[1], fgs) = 0,
                        toUInt32(run[length(run)]),
                        least(arrayFirst(x -> x > run[1], fgs), toUInt32(run[length(run)]))))])
            ))) AS pause_windows
        FROM runs
    ),

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
    app_version,
    audio_language,
    subtitle_language,
    player_version,
    interval_start,
    interval_end,
    is_open,
    build_version
FROM
(
    SELECT
        video_session_id,
        toDateTime64(seg.1, 3)                     AS interval_start,
        toDateTime64(seg.2 + if(seg.2 = run_end, tail_fc, 0), 3) AS interval_end,
        is_open,
        toUInt64(toUnixTimestamp(now())) AS build_version,
        arrayFilter(x -> (x.1 >= seg.1) AND (x.1 <= seg.2), dim_events) AS seg_events,
        arrayMap(x -> x.2, seg_events) AS v_app,
        arrayMap(x -> x.3, seg_events) AS v_audio,
        arrayMap(x -> x.4, seg_events) AS v_sub,
        arrayMap(x -> x.5, seg_events) AS v_player,
        arrayMap(x -> x.6, seg_events) AS v_user,
        arrayMap(x -> x.7, seg_events) AS v_content,
        arrayMap(x -> x.8, seg_events) AS v_platform,
        arrayMap(x -> x.9, seg_events) AS v_country,
        arraySort(v -> (-toInt64(countEqual(v_app,    v)), v), arrayDistinct(v_app))[1]    AS app_version,
        arraySort(v -> (-toInt64(countEqual(v_audio,  v)), v), arrayDistinct(v_audio))[1]  AS audio_language,
        arraySort(v -> (-toInt64(countEqual(v_sub,    v)), v), arrayDistinct(v_sub))[1]    AS subtitle_language,
        arraySort(v -> (-toInt64(countEqual(v_player, v)), v), arrayDistinct(v_player))[1] AS player_version,
        arraySort(v -> (-toInt64(countEqual(v_user,     v)), v), arrayDistinct(v_user))[1]     AS user_id,
        arraySort(v -> (-toInt64(countEqual(v_content,  v)), v), arrayDistinct(v_content))[1]  AS content_id,
        arraySort(v -> (-toInt64(countEqual(v_platform, v)), v), arrayDistinct(v_platform))[1] AS platform,
        arraySort(v -> (-toInt64(countEqual(v_country,  v)), v), arrayDistinct(v_country))[1]  AS country
    FROM folded
    ARRAY JOIN
        arrayFilter(x -> x.2 > x.1,
            arrayPushBack(fold.1, (fold.2, toUInt32(run_end)))
        ) AS seg
);
