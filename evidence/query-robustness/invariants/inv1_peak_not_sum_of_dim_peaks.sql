-- inv1 — PEAK IS NOT THE SUM OF PER-DIMENSION PEAKS (ARCHITECTURE rule 1).
-- Three numbers over the whole dataset: the true global peak (independent
-- interval expansion), the serving layer's headline peak (day tier), and the
-- sum of per-platform peaks. The serving answer must equal truth; the sum must
-- NOT be presented as a peak — it overcounts whenever platforms peak at
-- different minutes. FAIL if serving != truth, or if the sum did not exceed
-- truth (which would mean this dataset cannot demonstrate the trap).
WITH
    per_minute AS
    (
        SELECT minute, uniqExact(video_session_id) AS c
        FROM
        (
            SELECT video_session_id,
                   toDateTime(arrayJoin(range(
                       toUInt32(toStartOfMinute(interval_start)),
                       toUInt32(toStartOfMinute(interval_end)) + 60, 60))) AS minute
            FROM session_intervals FINAL
        )
        GROUP BY minute
    ),
    per_platform_minute AS
    (
        SELECT platform, minute, uniqExact(video_session_id) AS c
        FROM
        (
            SELECT video_session_id, platform,
                   toDateTime(arrayJoin(range(
                       toUInt32(toStartOfMinute(interval_start)),
                       toUInt32(toStartOfMinute(interval_end)) + 60, 60))) AS minute
            FROM session_intervals FINAL
        )
        GROUP BY platform, minute
    ),
    (SELECT max(c) FROM per_minute)                                    AS truth_peak,
    (SELECT sum(pk) FROM (SELECT max(c) AS pk FROM per_platform_minute
                          GROUP BY platform))                          AS sum_of_platform_peaks,
    (SELECT max(peak) FROM v_concurrency_day_total)                    AS serving_peak
SELECT
    'peak_not_sum_of_dim_peaks'                          AS invariant,
    truth_peak,
    serving_peak,
    sum_of_platform_peaks,
    if(serving_peak != truth_peak,
       concat('FAIL: serving headline peak ', toString(serving_peak),
              ' != truth ', toString(truth_peak)),
       if(sum_of_platform_peaks <= truth_peak,
          'FAIL: dataset cannot demonstrate the trap (sum <= truth)',
          'PASS'))                                       AS verdict
