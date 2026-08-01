-- evidence/explicit-state/analysis.sql — query-only agreement + unmatched-pair
-- probes over default.ev_raw and the reproduced baseline exs_q12.si_baseline.
-- Run each statement with tools/ch "$(…)"; outputs captured in out/agreement.txt.

-- Q1 · Per-event agreement: what does the event stream look like around each
-- AppBackgrounded? (next_ev = next event of ANY type in the session)
WITH per AS (
  SELECT video_session_id,
    arraySort(groupArray(toUnixTimestamp(event_timestamp))) AS ts,
    arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event_type='AppBackgrounded')) AS bgs,
    arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event_type='AppForegrounded')) AS fgs
  FROM default.ev_raw GROUP BY video_session_id)
SELECT
  count() AS bg_events,
  countIf(arrayFirst(x -> x >= b, fgs) = 0) AS unclosed_bg,
  countIf(next_ev = 0) AS bg_last_event_of_session,
  countIf(next_ev > 0 AND next_ev - b > 150) AS gap_gt150_starts_at_bg,
  countIf(has_gap_within_150) AS gap_gt150_starts_within_150s,
  countIf(next_ev > 0 AND next_ev - b <= 60) AS next_event_within_60s
FROM (
  SELECT b,
    arrayFirst(x -> x > b, ts) AS next_ev,
    arrayExists(i -> ts[i] >= b AND ts[i] <= b + 150 AND i < length(ts) AND ts[i+1] - ts[i] > 150,
                arrayEnumerate(ts)) AS has_gap_within_150,
    fgs
  FROM per ARRAY JOIN bgs AS b)
FORMAT Vertical;

-- Q2 · THE agreement number: seconds inside explicit bg->fg windows
-- (unclosed -> last event of the session) that the shipped baseline still
-- counts as watching. Baseline intervals are disjoint per session (adversarial
-- ledger row 12), so summing pairwise intersections is exact.
WITH per AS (
  SELECT video_session_id,
    arraySort(groupArray(toUnixTimestamp(event_timestamp))) AS ts,
    arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event_type='AppBackgrounded')) AS bgs,
    arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event_type='AppForegrounded')) AS fgs
  FROM default.ev_raw GROUP BY video_session_id),
win AS (
  SELECT video_session_id, toInt64(b) AS w1,
         toInt64(if(arrayFirst(x -> x >= b, fgs) = 0, ts[length(ts)], arrayFirst(x -> x >= b, fgs))) AS w2
  FROM per ARRAY JOIN bgs AS b),
iv AS (
  SELECT video_session_id, toInt64(toUnixTimestamp(interval_start)) AS s,
         toInt64(toUnixTimestamp(interval_end)) AS e
  FROM exs_q12.si_baseline)
SELECT
  (SELECT countIf(w2 > w1) FROM win) AS bg_windows,
  (SELECT round(sum(w2 - w1)/3600, 1) FROM win WHERE w2 > w1) AS bg_hours,
  round(sum(greatest(0, least(w2, e) - greatest(w1, s)))/3600, 1) AS counted_as_watching_h
FROM win INNER JOIN iv USING (video_session_id)
FORMAT Vertical;

-- Q3 · WHY the overlap is so small although 60% of bg events see another event
-- within 60 s: an explicit pause almost always precedes the background, so the
-- pause windows (not the gap) already exclude the chatter that follows.
WITH per AS (
  SELECT video_session_id,
    arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event_type='AppBackgrounded')) AS bgs,
    arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event = 'pause')) AS pauses
  FROM default.ev_raw GROUP BY video_session_id)
SELECT
  countIf(arrayExists(p -> p >= toInt64(b) - 10 AND p <= toInt64(b), arrayMap(x -> toInt64(x), pauses))) AS pause_within_10s_before_bg,
  countIf(arrayExists(p -> p >= toInt64(b) - 60 AND p <= toInt64(b), arrayMap(x -> toInt64(x), pauses))) AS pause_within_60s_before_bg,
  count() AS bg_events
FROM per ARRAY JOIN bgs AS b
FORMAT Vertical;

-- Q4 · Unmatched-pair recount, per session (ADR 0007 cited the GLOBAL count
-- difference 14,700 - 14,321 = 379; the per-session truth is below), plus the
-- orphan foregrounds and how widespread bg events are.
WITH per AS (
  SELECT video_session_id,
    arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event_type='AppBackgrounded')) AS bgs,
    arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event_type='AppForegrounded')) AS fgs
  FROM default.ev_raw GROUP BY video_session_id)
SELECT
  (SELECT count() FROM per ARRAY JOIN fgs AS f WHERE arrayFirst(x -> x <= f, arrayReverseSort(bgs)) = 0) AS orphan_fg_no_prior_bg,
  (SELECT countIf(length(bgs) > 0) FROM per) AS sessions_with_bg,
  (SELECT count() FROM per) AS sessions
FORMAT Vertical;
