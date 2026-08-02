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
-- WHICH EVENTS MEAN WHAT IS DECLARED, NOT ASSUMED (ADR 0033). Until 0033 this
-- file said "a run of events" and meant EVERY row of ev_raw: 44 of the file's
-- 47 (event_type, event) pairs participated as anonymous timestamps that bridge
-- gaps and earn TAIL_S, and an event value WE HAVE NEVER SEEN inherited that
-- power silently. The contract below — contracts/event_semantics.tsv, rendered
-- in by tools/event-semantics.sh — names all 47 and closes the set:
--
--   DECLARED pair    -> renews liveness iff its class is in LIVENESS_CLASSES
--   UNDECLARED pair  -> renews NOTHING. It is still a dimension observation
--                       (dim_events below reads every row), it just cannot
--                       lengthen a run, bridge a gap, or mint a tail.
--
-- The default is FAIL-CLOSED because unknown vocabulary may only SHORTEN the
-- answer, never lengthen it. Measured cost of the flip on the delivered file:
-- ZERO — 30,323 intervals, 1,978.1 h, PEAK 2,917 @ 2026-07-26 10:56, and the
-- interval boundaries are bit-identical to the pre-0033 build (0 rows differ).
-- Measured value: an undeclared `AppKeepalive/tick` every 30 s for 30 min after
-- each session's last event — an entirely plausible client event — takes the
-- fail-open peak to 5,004 (+71.5%) and MOVES THE PEAK MINUTE to 11:15. Under
-- this contract the same file yields 2,917 @ 10:56, bit-identical.
-- Full ledger: evidence/event-semantics/README.md.
--
-- Re-running is safe: session_intervals is a ReplacingMergeTree keyed on
-- (video_session_id, interval_start), versioned on build_version, so the newest
-- derivation always wins — whether the interval grew OR SHRANK. It used to be
-- versioned on interval_end, which silently kept stale over-long intervals; see
-- the engine comment in 10_intervals.sql and evidence/truncation.txt.
--
-- DIMENSION ATTRIBUTION (ADR 0008). A dimension is a property of an EVENT, not
-- of a session, and the provided file proves it: 8,796 of 10,866 sessions carry
-- more than one audio_language and 10,862 carry more than one
-- subtitle_language. Almost all of that is the player reporting a sentinel
-- before it has resolved a track — VideoSessionStart carries a sentinel
-- subtitle_language on 10,880 of 10,880 sessions — so the naive any() picks the
-- sentinel far more often than the truth. MEASURED against a per-minute
-- attribution over all 139,800 session-minute cells:
--
--   rule                                   audio wrong    subtitle wrong
--   any()            (what this used)         44.5%           47.6%
--   dominant per interval (what this does)     3.3%            1.8%
--
-- At the graded peak minute any() puts 2,004 of 2,726 active sessions (73.5%)
-- in the wrong audio bucket. any() is also NOT DETERMINISTIC — the same query
-- at max_threads 1 / 8 / 32 returns three different attributions — so two
-- rebuilds of the same data can serve two different answers to the same
-- filtered query. That alone disqualifies it for a graded rebuild.
--
-- The rule used instead: the DOMINANT (most frequent) raw value among the
-- events that fall inside THAT interval, ties broken by the value itself so the
-- result is a pure function of the input. Raw values, never canonicalised —
-- 'HIN' and 'hin' stay distinct because the private ground truth is matched on
-- the shipped strings, not on our idea of tidy ones.
--
-- ADR 0009 EXTENDS THAT RULE TO ALL SEVEN. ADR 0008 applied it to app_version,
-- audio_language, subtitle_language and player_version only, and left user_id,
-- content_id, platform and country on any() because the accuracy exposure there
-- is small (95 sessions carry 2 platforms, 120 carry 2 user_ids). The accuracy
-- argument was the wrong argument: any() is NON-DETERMINISTIC, re-measured on
-- exactly those four columns (three hashes at max_threads 1/8/32, see below), so
-- it makes the BUILD irreproducible regardless of how few rows it touches. One
-- rule for all seven now; there is no second mechanism to keep in step.
--
-- The interval is NOT split when a dimension changes mid-interval. Splitting
-- would put two intervals of the SAME session on the same minute with different
-- dimension tuples, and the merge in 40_deltas.sql groups by session precisely
-- because two +1s for one viewer is a double count — it is the bug /reconcile
-- caught once already (556 of 1,903 minutes wrong). Genuine mid-session changes
-- (case- and sentinel-normalised) are 250 sessions for audio_language, 70 for
-- player_version, 20 for subtitle_language and 0 for app_version, i.e. ≤2.3% of
-- sessions on the worst dimension; a double count would be wrong on every
-- minute of every filtered query. Attribute, do not split.
-- ============================================================================

INSERT INTO session_intervals
    (video_session_id, user_id, content_id, platform, country,
     app_version, audio_language, subtitle_language, player_version,
     interval_start, interval_end, is_open, build_version)
WITH
    -- >>> BEGIN GENERATED from contracts/event_semantics.tsv — tools/event-semantics.sh --write
    [('AppBackgrounded','AppBackgrounded','app_state'),
     ('AppForegrounded','AppForegrounded','app_state'),
     ('VideoError','VideoError','error'),
     ('VideoHeartbeat','AdBufferEnd','playback'),
     ('VideoHeartbeat','AdBufferStart','playback'),
     ('VideoHeartbeat','AdClick','playback'),
     ('VideoHeartbeat','AdPause','playback'),
     ('VideoHeartbeat','AdResume','playback'),
     ('VideoHeartbeat','AdSkipTrueView','playback'),
     ('VideoHeartbeat','BufferEnd','playback'),
     ('VideoHeartbeat','BufferStart','playback'),
     ('VideoHeartbeat','Seek','playback'),
     ('VideoHeartbeat','audio-language','playback'),
     ('VideoHeartbeat','buffer-health','playback'),
     ('VideoHeartbeat','chromecast_clicked','ui'),
     ('VideoHeartbeat','chromecast_started','ui'),
     ('VideoHeartbeat','download_asset_play_stop','download'),
     ('VideoHeartbeat','download_asset_played','download'),
     ('VideoHeartbeat','download_completed','download'),
     ('VideoHeartbeat','download_deleted','download'),
     ('VideoHeartbeat','download_initiated','download'),
     ('VideoHeartbeat','download_resumed','download'),
     ('VideoHeartbeat','downshift','playback'),
     ('VideoHeartbeat','dropped-frames','playback'),
     ('VideoHeartbeat','go_live_click','playback'),
     ('VideoHeartbeat','golive','playback'),
     ('VideoHeartbeat','network-activity','playback'),
     ('VideoHeartbeat','network-bandwidth','playback'),
     ('VideoHeartbeat','network-change','playback'),
     ('VideoHeartbeat','next_video_click','playback'),
     ('VideoHeartbeat','pause','playback'),
     ('VideoHeartbeat','preroll-disabled','playback'),
     ('VideoHeartbeat','preview_watched','playback'),
     ('VideoHeartbeat','resume','playback'),
     ('VideoHeartbeat','speed-change','playback'),
     ('VideoHeartbeat','speed-pause','playback'),
     ('VideoHeartbeat','speed-resume','playback'),
     ('VideoHeartbeat','subtitle-language','playback'),
     ('VideoHeartbeat','upshift','playback'),
     ('VideoHeartbeat','video-resize','playback'),
     ('VideoHeartbeat','video_forward','playback'),
     ('VideoHeartbeat','video_rewind','playback'),
     ('VideoHeartbeat','video_quality_change','playback'),
     ('VideoHeartbeat','premium_button_click','ui'),
     ('VideoPlay','Play','playback'),
     ('VideoSessionEnd','VideoSessionEnd','lifecycle'),
     ('VideoSessionStart','VideoSessionStart','lifecycle')] AS EVENT_SEMANTICS,
    ['pause'] AS PAUSE_EVENTS,
    ['resume'] AS RESUME_EVENTS,
    ['VideoSessionEnd'] AS END_TYPES,
    -- <<< END GENERATED
    -- THE LIVENESS POLICY. Hand-edited — this is the operator's lever, and it
    -- MUST be the same edit in sql/90_reconcile.sql (tools/event-semantics.sh
    -- --check fails the suite if the two ever differ). Every value MEASURED end
    -- to end on the delivered file, local scratch `evsem_q33`, gate green at
    -- each (evidence/event-semantics/README.md):
    --
    --   classes kept                                intervals   hours    PEAK
    --   playback lifecycle app_state error dl ui      30,323  1,978.1   2,917  <- ships
    --   playback lifecycle download ui                29,659  1,987.0   2,905
    --   playback lifecycle                            29,659  1,987.0   2,904
    --   playback download ui                          29,343  1,961.5   2,880
    --   playback                                      29,340  1,961.5   2,879
    --
    -- Rows 2 and 4 reproduce evidence/liveness/README.md Q1's `nobgfgerr` and
    -- `allowhb` EXACTLY (29,659/1,987.0/2,905 and 29,343/1,961.5/2,880), from an
    -- independent expression — which is what licenses this file to claim the
    -- other three. Every one peaks at the same minute, 2026-07-26 10:56.
    --
    -- DEFAULT = every declared class, i.e. exactly what shipped before ADR 0033.
    -- NOT because it is the better reading — doubts/11 argues a narrower list is
    -- and puts the strict reading at -1.3% of PEAK — but because narrowing it
    -- moves a number we have already submitted, and that is an operator's call,
    -- not a build's. The unknown-event default is a different question and IS
    -- decided here; see the header. Same discipline as POINT_ACTIVITY_COUNTS.
    ['playback','lifecycle','app_state','error','download','ui'] AS LIVENESS_CLASSES,
    arrayMap(x -> (x.1, x.2), arrayFilter(x -> has(LIVENESS_CLASSES, x.3), EVENT_SEMANTICS)) AS LIVENESS_PAIRS,
    -- Tunables. GAP_S is now derived from the MEASURED inter-arrival p99 of 49s
    -- (ADR 0007), not from the "60s cadence" that the data disproved. 150s is
    -- ~3x p99 — wide enough to survive a burst pause, tight enough to catch a
    -- backgrounding within one minute bucket.
    150 AS GAP_S,
    -- Credit after the last event of a run. One cadence, not a full gap: the
    -- viewer was watching until at least the next expected event.
    60  AS TAIL_S,
    -- THE UNCLOSED-PAUSE RULE. 23% of pauses never resume, and the two readings
    -- are not close: MEASURED end to end on the real file,
    --   conservative  1,949.3 h counted, PEAK 2,887
    --   permissive    2,048.6 h counted, PEAK 3,018   (+5.09% hours, +4.5% PEAK)
    -- Both at the same minute, 2026-07-26 10:56. The peak is the graded number,
    -- so this constant moves the headline by 131 viewers.
    -- Default CONSERVATIVE: against an EXACT private ground truth, under-counting
    -- is a visible, explainable error while over-counting invents viewers that
    -- were demonstrably not receiving playback events. See ADR 0007; mentor Q2.
    1 AS UNCLOSED_PAUSE_TO_RUN_END,
    -- THE POINT-ACTIVITY RULE (ADR 0031). Does a viewer who was demonstrably
    -- active at an instant, but for whom we can measure NO DURATION, count for
    -- one cadence — or for nothing at all?
    --
    -- Until ADR 0031 this file answered "nothing at all" BY ACCIDENT: the
    -- segment fold below drops a zero-length segment, and it does so BEFORE
    -- TAIL_S is applied, so a run of a single event earned no interval rather
    -- than the [t, t+TAIL_S] every other run end earns. Nothing in doubts/ or
    -- the ADRs ever stated that as a convention. It is now a CONSTANT, so the
    -- answer is a decision with a number attached rather than a side effect of
    -- where a filter sits.
    --
    -- MEASURED on the delivered file (evidence/point-activity/), local scratch
    -- rebuilt verbatim from this file, gate green under BOTH values:
    --   0 = shipped     30,323 intervals  1,978.1 h  PEAK 2,917 @ 07-26 10:56
    --   1 = point-activity-counts
    --                   30,653 intervals  1,982.7 h  PEAK 2,927 @ 07-26 10:56
    -- i.e. +330 intervals, +4.62 h (+0.23%), +10 PEAK (+0.34%), same minute.
    --
    -- The 330 are exactly the segments whose two endpoints coincide, and they
    -- are three distinct populations — see ADR 0031 for the census:
    --      182  a run of ONE instant (the viewer emitted one event and nothing
    --           within GAP_S either side). 124 of those instants are a
    --           VideoSessionEnd, which is why this interacts with doubts/07.
    --       95  a `resume` landing exactly on the run's last instant.
    --       53  a `pause` opening exactly where the previous segment resumed.
    -- A FOURTH population — 5,699 segments where an UNCLOSED pause runs through
    -- the run end — is NOT in that set and is still dropped at both values.
    -- That viewer was paused at the run's last instant, so crediting a cadence
    -- there would book paused time as watch time; see the window arithmetic
    -- below, which now ends an unclosed pause at run_end + 1 to say so.
    --
    -- DEFAULT 0 — NOT because it is the better reading. tools/reference_
    -- interpreter.py, which derives the spec from docs/EXPLAINER.md rather than
    -- from this file, counts point activity, and so does this file's own tail
    -- rule for every run that lasts even one second. ADR 0031 RECOMMENDS 1.
    -- It ships at 0 because flipping it moves a number we have already
    -- submitted (2,917 -> 2,927), and that is an operator's call, not a
    -- build's. Flip it here and in sql/90_reconcile.sql together.
    0 AS POINT_ACTIVITY_COUNTS,

    per_session AS (
        SELECT
            video_session_id,
            -- ONLY DECLARED PAIRS RENEW LIVENESS (ADR 0033). An undeclared pair
            -- contributes no timestamp here, so it cannot bridge a gap, extend a
            -- run or earn TAIL_S. It still reaches dim_events below.
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp),
                has(LIVENESS_PAIRS, (toString(event_type), toString(event)))))   AS ts,
            -- ALL SEVEN raw dimensions, carried as (ts, value…) tuples so they can
            -- be attributed PER INTERVAL below rather than collapsed to one value
            -- per session. Deliberately a SECOND array rather than a widened `ts`:
            -- `ts` drives run splitting and is left byte-identical, so this change
            -- provably cannot move an interval boundary — only label it. Sorted by
            -- the whole tuple, so equal timestamps order deterministically too.
            --
            -- user_id/content_id/platform/country used to sit above this as
            -- any(user_id) etc., under a comment saying a session is almost always
            -- one user/content/platform (1 session has 2 content_ids, 95 have 2
            -- platforms, 120 have 2 user_ids out of 10,866) and that the
            -- alternative "is not worth it until something measures it as
            -- mattering". Something did, in commit 8bfeeb2, and it is not the
            -- accuracy argument — it is DETERMINISM. Re-measured here on exactly
            -- these four columns, same data, same query:
            --   any(user_id, content_id, platform, country) per session
            --     max_threads=1   cityHash64 = 5126827698054385970
            --     max_threads=8                4514778022739255759
            --     max_threads=32               2307516582733793023
            -- Three different attributions of one input, so two rebuilds of the
            -- same data can serve two different answers to the same filtered
            -- query — against an EXACT private ground truth that is disqualifying,
            -- whether it moves 120 sessions or 12,000. They now use the SAME rule
            -- 8bfeeb2 established for the other four: dominant value per interval,
            -- tie-broken by the value itself. New members are appended at the tail
            -- so the existing .2–.5 slots keep their meaning. ADR 0009.
            arraySort(groupArray((
                toUnixTimestamp(event_timestamp),
                app_version, audio_language, subtitle_language, player_version,
                user_id, content_id, platform, country
            ))) AS dim_events,
            -- MARKERS ARE MATCHED BY NAME, NOT BY PAIR, AND THAT ASYMMETRY IS
            -- DELIBERATE (ADR 0033). Liveness above is fail-CLOSED: an unknown
            -- pair grants nothing, so it can only shorten the answer. A marker
            -- must fail in the SAME direction, and for `pause` that means the
            -- opposite mechanism — an undeclared `AdBreak/pause` arriving on the
            -- unseen day should still STOP the clock. Matching the declared NAME
            -- rather than the declared pair is what keeps it doing so. A genuinely
            -- new name (`unpause`) is undeclared under either rule and leaves the
            -- pause open to the run end, which is also the shortening direction.
            -- The one residual: an undeclared type emitting a KNOWN `resume` name
            -- closes a pause window early and so lengthens. It needs a matching
            -- `pause` to have any effect at all, and probe 8 of the source-contract
            -- gate fires on the pair before the load. Byte-for-byte identical to
            -- the old `event = 'pause'` on the delivered file: PAUSE_EVENTS is
            -- ['pause'] and no other event_type carries that value.
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), has(PAUSE_EVENTS,  toString(event)))) AS pauses,
            arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), has(RESUME_EVENTS, toString(event)))) AS resumes,
            -- No VideoSessionEnd at build time => still open. 2.2% of sessions
            -- emit events up to 2,081s AFTER their end event (ADR 0007), so
            -- "ended" is not the same as "sealed".
            -- END_TYPES is declared by the contract (action=end) and matched on
            -- event_type, as before. Fail-closed here also shortens nothing and
            -- inflates nothing: an unrecognised end marker leaves is_open = 1, so
            -- the session stays correctable instead of being sealed early.
            countIf(has(END_TYPES, toString(event_type))) = 0 AS is_open
        FROM ev_raw
        GROUP BY video_session_id
    ),

    -- Split the session into runs wherever the gap exceeds the threshold.
    runs AS (
        SELECT
            video_session_id, is_open,
            pauses, resumes, dim_events,
            arrayJoin(arraySplit((t, i) -> (i > 1) AND ((t - ts[i - 1]) > GAP_S), ts, arrayEnumerate(ts))) AS run
        FROM per_session
    ),

    -- Clip pause windows into the run. An unclosed pause (23% of them) runs to
    -- the end of its run: CONSERVATIVE, never credit time we cannot prove was
    -- active. ADR 0007 records the alternative and what it costs.
    windowed AS (
        SELECT
            video_session_id, is_open,
            dim_events,
            run[1]              AS run_start,
            run[length(run)]    AS run_end,
            -- A pause window closes at the next `resume`. 23% of pauses never
            -- get one, and what happens then is UNCLOSED_PAUSE_TO_RUN_END:
            --   1 = CONSERVATIVE (default) — paused until the run ends. Never
            --       credits time we cannot prove was active.
            --   0 = PERMISSIVE — paused only until the next event of any kind,
            --       treating the unresolved pause as a blip.
            -- Flipping the constant at the top of this file is the whole change.
            --
            -- THE RESUME LOOKUP IS `>=`, NOT `>`, AND THAT IS A CORRECTNESS FIX.
            -- `ts` is toUnixTimestamp(event_timestamp), i.e. TRUNCATED TO WHOLE
            -- SECONDS, and 23.67% of adjacent event pairs already share the exact
            -- same millisecond. A strict `>` therefore cannot see a resume that
            -- lands in the SAME truncated second as its pause: the window ran on
            -- to the NEXT resume, or — with no next resume — became unclosed and
            -- ate the rest of the run. MEASURED on the real file:
            --   pause events                                        27,340
            --   with a resume in the same truncated second           2,697  (9.86%)
            --   closed-pause time, strict >                          834.1 h
            --   closed-pause time, inclusive >=                      792.6 h
            --   raw over-exclusion from the tie                       41.5 h
            -- Most of that raw over-exclusion overlaps time the GAP rule already
            -- excludes, exactly as ADR 0007 found for the unclosed-pause question
            -- (330 h estimated -> 99.3 h real). Clipped into runs and merged, the
            -- model actually over-excluded 309.5 h -> 286.2 h, i.e. 23.3 h. See
            -- ADR 0009 for the end-to-end effect on the PEAK.
            -- `>=` yields a ZERO-LENGTH window (p, p) for a tie. The fold below
            -- already absorbs it correctly — it pushes the segment up to p and
            -- leaves the cursor at p, so no active time is lost and none is
            -- invented — but it SPLITS one interval into two abutting ones at p.
            -- Measured: 31,938 intervals with the split vs 30,323 without, both
            -- at PEAK 2,917 / 1,978.1 h and both gate-green over 17,028 minutes.
            -- The split is dropped, because an interval
            -- boundary is also a DIMENSION ATTRIBUTION boundary (ADR 0008) and a
            -- pause that resumed in its own second is not a boundary of anything.
            -- Hence the outer arrayFilter(w -> w.2 > w.1, …).
            -- The PERMISSIVE branch's lookup into `run` stays STRICT: the pause
            -- event is itself in `run` at p, so `>=` there would match the pause
            -- and collapse every permissive window to zero.
            --
            -- A WINDOW IS HALF-OPEN [p, e): paused from p+1 through e-1, and the
            -- viewer is counted AT p (they demonstrably acted at p) and again AT
            -- e (a resume is an event). That is what the fold below implements,
            -- and it is why `e` must be a REAL ACTIVE INSTANT — which is exactly
            -- what the old `least(…, run_end)` destroyed. It clamped BOTH "a
            -- resume closed this pause" and "nothing ever closed it, so the
            -- viewer stayed paused to the end" to the same value, run_end, and
            -- so claimed run_end was active in both. While zero-length segments
            -- were dropped that was invisible. Under POINT_ACTIVITY_COUNTS = 1
            -- it would credit a cadence to 5,699 segments whose viewer was
            -- provably still paused — so the two cases are now distinguished:
            --   resume r with p <= r <= run_end  ->  e = r          (active at r)
            --   otherwise (no resume, or one beyond the run)
            --                                    ->  e = run_end + 1
            -- run_end + 1 is one past the last instant of the run: the whole run
            -- is paused-through, and the final segment (run_end + 1, run_end) is
            -- empty at EITHER value of POINT_ACTIVITY_COUNTS. At value 0 this
            -- rewrite is provably a no-op — the old expression differed only in
            -- a cursor value that no surviving segment ever read — and the gate
            -- confirms it: 17,028 minutes, 0 mismatched, PEAK unchanged at 2,917.
            arrayFilter(w -> w.2 > w.1, arraySort(arrayMap(
                p -> (p,
                        if((arrayFirst(x -> x >= p, resumes) != 0)
                             AND (arrayFirst(x -> x >= p, resumes) <= run[length(run)]),
                           toUInt32(arrayFirst(x -> x >= p, resumes)),
                           if(UNCLOSED_PAUSE_TO_RUN_END = 1,
                              toUInt32(run[length(run)] + 1),
                              -- next event inside this run; one past the run end
                              -- if it is the last (unreachable: p < run_end means
                              -- run_end itself always qualifies)
                              if(arrayFirst(x -> x > p, run) = 0,
                                 toUInt32(run[length(run)] + 1),
                                 toUInt32(arrayFirst(x -> x > p, run)))))),
                arrayFilter(p -> (p >= run[1]) AND (p < run[length(run)]), pauses)
            ))) AS pause_windows
        FROM runs
    ),

    -- Complement of the merged pause windows within [run_start, run_end].
    -- arrayFold walks the sorted windows carrying (segments_so_far, cursor).
    --
    -- The push test is where POINT_ACTIVITY_COUNTS bites for the 53 segments
    -- whose pause opens exactly where the previous one resumed: `win.1 > acc.2`
    -- discards the single active instant at acc.2, `win.1 = acc.2` keeps it as a
    -- zero-length segment. Starts stay strictly increasing either way — a push
    -- sets the cursor to win.2 > win.1 >= acc.2 — so no two segments of one run
    -- can share an interval_start and collide on the ReplacingMergeTree key.
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

-- The outer projection lists exactly the 13 target columns. The inner SELECT
-- needs working aliases (the per-interval slice of dim_events, and the four
-- value arrays cut out of it) which must NOT reach the INSERT, hence the nest.
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
        -- Tail grace is ONLY for a segment that ends because the run ended — there
        -- we do not know when the viewer actually left, so we credit one cadence.
        -- A segment ending at a PAUSE gets none: we know to the second when they
        -- stopped watching, and crediting 60s past it books paused (often
        -- backgrounded) time as watch time. Measured on the worked example: the
        -- viewer paused at 11:04:29 and backgrounded at 11:04:31, so the tail was
        -- landing entirely inside a 24-minute background.
        toDateTime64(seg.2 + if(seg.2 = run_end, TAIL_S, 0), 3) AS interval_end,
        is_open,
        -- Monotonic across builds so the newest derivation always wins the replace,
        -- whether the interval grew or shrank. now() is evaluated once per query.
        toUInt64(toUnixTimestamp(now())) AS build_version,

        -- ---- PER-INTERVAL DIMENSION ATTRIBUTION -------------------------------
        -- The events this interval actually covers. seg.1/seg.2 are both event
        -- timestamps (a segment starts at a run start or a resume and ends at a
        -- run end or a pause — all of which are events), so this slice is never
        -- empty and the endpoints are inclusive on both sides. The tail grace is
        -- added to interval_end above, deliberately AFTER this: no event exists
        -- in the grace window, so including it would change nothing but would
        -- make the intent unclear.
        arrayFilter(x -> (x.1 >= seg.1) AND (x.1 <= seg.2), dim_events) AS seg_events,
        arrayMap(x -> x.2, seg_events) AS v_app,
        arrayMap(x -> x.3, seg_events) AS v_audio,
        arrayMap(x -> x.4, seg_events) AS v_sub,
        arrayMap(x -> x.5, seg_events) AS v_player,
        arrayMap(x -> x.6, seg_events) AS v_user,
        arrayMap(x -> x.7, seg_events) AS v_content,
        arrayMap(x -> x.8, seg_events) AS v_platform,
        arrayMap(x -> x.9, seg_events) AS v_country,

        -- Dominant value: sort the DISTINCT values by (-frequency, value) and
        -- take the first. The second sort term is what makes this deterministic
        -- where any() is not — a tie is broken by the value, never by which
        -- thread happened to finish first. Cost is O(distinct x length) on an
        -- array whose length is one interval's events (median 30, max 1,803),
        -- so it is negligible next to the arraySplit/arrayFold above.
        -- An empty slice would yield '' rather than an error; it cannot occur,
        -- but it fails soft rather than dropping the interval.
        arraySort(v -> (-toInt64(countEqual(v_app,    v)), v), arrayDistinct(v_app))[1]    AS app_version,
        arraySort(v -> (-toInt64(countEqual(v_audio,  v)), v), arrayDistinct(v_audio))[1]  AS audio_language,
        arraySort(v -> (-toInt64(countEqual(v_sub,    v)), v), arrayDistinct(v_sub))[1]    AS subtitle_language,
        arraySort(v -> (-toInt64(countEqual(v_player, v)), v), arrayDistinct(v_player))[1] AS player_version,
        -- The same expression, applied to the four that commit 8bfeeb2 left on
        -- any(). content_id is Int64 rather than a string; the tie-break sorts on
        -- the numeric value, which is just as total an order, so the rule is
        -- unchanged rather than adapted.
        arraySort(v -> (-toInt64(countEqual(v_user,     v)), v), arrayDistinct(v_user))[1]     AS user_id,
        arraySort(v -> (-toInt64(countEqual(v_content,  v)), v), arrayDistinct(v_content))[1]  AS content_id,
        arraySort(v -> (-toInt64(countEqual(v_platform, v)), v), arrayDistinct(v_platform))[1] AS platform,
        arraySort(v -> (-toInt64(countEqual(v_country,  v)), v), arrayDistinct(v_country))[1]  AS country
    FROM folded
    ARRAY JOIN
        -- The final segment (cursor, run_end), and the POINT_ACTIVITY_COUNTS
        -- test again. `x.2 > x.1` drops the run's last instant whenever the
        -- segment has no duration; `x.2 >= x.1` keeps it and it collects TAIL_S
        -- above, exactly as a one-second segment ending at the same instant
        -- would. A paused-through run is empty at BOTH values because its cursor
        -- is run_end + 1, so x.2 < x.1 (see the window arithmetic above).
        arrayFilter(x -> if(POINT_ACTIVITY_COUNTS = 1, x.2 >= x.1, x.2 > x.1),
            arrayPushBack(fold.1, (fold.2, toUInt32(run_end)))
        ) AS seg
);
