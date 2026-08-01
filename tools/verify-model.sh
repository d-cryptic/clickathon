#!/usr/bin/env bash
# Verify the invariants the batch spine can prove without a private answer key:
# hard stops and dimension handoffs never remain inside an interval, and delta
# reconstruction matches direct interval overlap on busy platform-minute samples.
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$root_dir"
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

target=${TARGET:-local}
result=$(TARGET="$target" "$root_dir/tools/ch-run.sh" --multiquery --stdin <<'SQL'
WITH targets AS
(
    SELECT platform, toStartOfMinute(interval_start) AS minute, count() AS starts
    FROM session_intervals
    GROUP BY platform, minute
    ORDER BY starts DESC, platform, minute
    LIMIT 5
), direct AS
(
    SELECT
        targets.platform,
        targets.minute,
        countIf(interval_start < targets.minute + toIntervalMinute(1) AND interval_end > targets.minute) AS concurrency
    FROM targets
    INNER JOIN session_intervals USING (platform)
    GROUP BY targets.platform, targets.minute
), served AS
(
    SELECT
        targets.platform,
        targets.minute,
        sum(delta) AS concurrency
    FROM targets
    LEFT JOIN cc_minute_delta
        ON cc_minute_delta.platform = targets.platform
       AND toStartOfHour(cc_minute_delta.minute) = toStartOfHour(targets.minute)
       AND cc_minute_delta.minute <= targets.minute
    GROUP BY targets.platform, targets.minute
)
SELECT
    'delta_mismatches' AS check,
    countIf(direct.concurrency != served.concurrency) AS failures
FROM direct
INNER JOIN served USING (platform, minute)
UNION ALL
SELECT
    'stop_markers_inside_intervals',
    countIf(interval_start < event_timestamp AND event_timestamp < interval_end)
FROM session_intervals
INNER JOIN ev_raw USING (video_session_id)
WHERE event_type IN ('AppBackgrounded', 'VideoSessionEnd') OR event = 'pause'
UNION ALL
SELECT
    'tied_stop_start_precedence_regression',
    countIf(stop_order >= resume_order OR resume_order >= heartbeat_order)
FROM
(
    SELECT
        maxIf(event_order, event = 'pause') AS stop_order,
        maxIf(event_order, event = 'resume') AS resume_order,
        maxIf(event_order, event = 'heartbeat') AS heartbeat_order
    FROM
    (
        SELECT
            event,
            toUnixTimestamp64Milli(toDateTime64('2026-01-01 10:00:00', 3)) * 10
              + multiIf(event = 'pause', 1, event = 'resume', 2, 5) AS event_order
        FROM
        (
            SELECT 'pause' AS event
            UNION ALL SELECT 'resume'
            UNION ALL SELECT 'heartbeat'
        )
    )
)
UNION ALL
SELECT
    'half_open_minute_boundary_regression',
    countIf(truth_concurrency != served_concurrency)
FROM
(
    WITH
        synthetic_intervals AS
        (
            SELECT toDateTime64('2026-01-01 10:00:00', 3) AS interval_start, toDateTime64('2026-01-01 10:05:00', 3) AS interval_end
            UNION ALL
            SELECT toDateTime64('2026-01-01 10:10:00', 3), toDateTime64('2026-01-01 10:15:00.001', 3)
            UNION ALL
            SELECT toDateTime64('2026-01-01 10:59:30', 3), toDateTime64('2026-01-01 11:00:00', 3)
        ),
        synthetic_clipped AS
        (
            SELECT
                interval_start,
                interval_end,
                toStartOfHour(interval_start) + toIntervalHour(hour_offset) AS hour
            FROM synthetic_intervals
            ARRAY JOIN range(dateDiff('hour', toStartOfHour(interval_start), toStartOfHour(interval_end)) + 1) AS hour_offset
        ),
        synthetic_deltas AS
        (
            SELECT toStartOfMinute(greatest(interval_start, hour)) AS minute, toInt64(1) AS delta
            FROM synthetic_clipped
            WHERE interval_start < hour + toIntervalHour(1) AND interval_end > hour
            UNION ALL
            SELECT
                if(
                    interval_end = toStartOfMinute(interval_end),
                    toStartOfMinute(interval_end),
                    toStartOfMinute(interval_end) + toIntervalMinute(1)
                ) AS minute,
                toInt64(-1) AS delta
            FROM synthetic_clipped
            WHERE
                interval_start < hour + toIntervalHour(1)
                AND interval_end > hour
                AND interval_end < hour + toIntervalHour(1)
                AND if(
                    interval_end = toStartOfMinute(interval_end),
                    toStartOfMinute(interval_end),
                    toStartOfMinute(interval_end) + toIntervalMinute(1)
                ) < hour + toIntervalHour(1)
        ),
        minutes AS
        (
            SELECT toDateTime('2026-01-01 10:00:00') + toIntervalMinute(number) AS minute
            FROM numbers(62)
        ),
        truth AS
        (
            SELECT
                minutes.minute,
                countIf(
                    interval_start < minutes.minute + toIntervalMinute(1)
                    AND interval_end > minutes.minute
                ) AS concurrency
            FROM minutes
            CROSS JOIN synthetic_intervals
            GROUP BY minutes.minute
        ),
        served AS
        (
            SELECT
                minutes.minute,
                sumIf(
                    synthetic_deltas.delta,
                    toStartOfHour(synthetic_deltas.minute) = toStartOfHour(minutes.minute)
                    AND synthetic_deltas.minute <= minutes.minute
                ) AS concurrency
            FROM minutes
            CROSS JOIN synthetic_deltas
            GROUP BY minutes.minute
        )
    SELECT
        truth.minute,
        truth.concurrency AS truth_concurrency,
        served.concurrency AS served_concurrency
    FROM truth
    INNER JOIN served USING (minute)
)
UNION ALL
SELECT
    'dimension_handoff_overlaps',
    countIf(
        previous_end > interval_start
        AND (previous_platform != platform OR previous_country != country OR previous_content_id != content_id)
    )
FROM
(
    SELECT
        *,
        lagInFrame(interval_end, 1, toDateTime64(0, 3)) OVER handoff_window AS previous_end,
        lagInFrame(platform, 1, '') OVER handoff_window AS previous_platform,
        lagInFrame(country, 1, '') OVER handoff_window AS previous_country,
        lagInFrame(content_id, 1, toInt64(0)) OVER handoff_window AS previous_content_id
    FROM session_intervals
    WINDOW handoff_window AS
        (PARTITION BY video_session_id ORDER BY interval_start ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
)
FORMAT TSVWithNames;
SQL
)

printf '%s\n' "$result" | column -t -s $'\t'

if printf '%s\n' "$result" | awk -F '\t' 'NR > 1 && $2 != 0 { exit 1 }'; then
  exit 0
fi

echo "model invariant verification failed" >&2
exit 1
