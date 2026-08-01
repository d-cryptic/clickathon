INSERT INTO y2_lone
WITH 150 AS GAP_S,
  per_session AS (
    SELECT video_session_id, arraySort(groupArray(toUnixTimestamp(event_timestamp))) AS ts
    FROM ev_raw GROUP BY video_session_id),
  runs AS (
    SELECT video_session_id,
      arrayJoin(arraySplit((t, i) -> (i > 1) AND ((t - ts[i - 1]) > GAP_S), ts, arrayEnumerate(ts))) AS run
    FROM per_session)
SELECT video_session_id, toUInt32(run[1]) FROM runs WHERE run[1] = run[length(run)];
