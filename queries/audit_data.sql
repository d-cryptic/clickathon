SELECT
    count() AS rows,
    uniqExact(tuple(content_id, video_session_id, user_id, event_type, event, event_timestamp, platform, app_version, country, audio_language, subtitle_language, player_version, session_start_epoch)) AS distinct_payloads,
    rows - distinct_payloads AS exact_duplicate_rows
FROM ev_raw
FORMAT PrettyCompact;

SELECT
    min(ingested_at) AS first_ingested_at,
    max(ingested_at) AS last_ingested_at,
    uniqExact(ingested_at) AS distinct_ingestion_timestamps,
    dateDiff('millisecond', min(ingested_at), max(ingested_at)) AS ingestion_span_ms,
    if(uniqExact(ingested_at) <= 1, 'BULK_LOAD_NOT_WATERMARK_TELEMETRY', 'ARRIVAL_TELEMETRY_PRESENT') AS watermark_measurement_status
FROM ev_raw
FORMAT PrettyCompact;

SELECT
    count() AS sessions,
    countIf(platforms > 1) AS platform_drift_sessions,
    countIf(countries > 1) AS country_drift_sessions,
    countIf(contents > 1) AS content_drift_sessions,
    countIf(users > 1) AS user_drift_sessions
FROM
(
    SELECT video_session_id, uniqExact(platform) AS platforms, uniqExact(country) AS countries,
        uniqExact(content_id) AS contents, uniqExact(user_id) AS users
    FROM ev_raw
    GROUP BY video_session_id
)
FORMAT PrettyCompact;

SELECT
    count() AS reused_video_session_ids,
    sum(incarnations) AS incarnations_in_reused_ids,
    max(incarnations) AS max_incarnations_per_video_session_id
FROM
(
    SELECT video_session_id, uniqExact(session_start_epoch) AS incarnations
    FROM ev_raw
    GROUP BY video_session_id
    HAVING incarnations > 1
)
FORMAT PrettyCompact;

SELECT
    countIf(events_at_timestamp > 1) AS timestamps_with_ties,
    max(events_at_timestamp) AS max_events_at_one_timestamp,
    countIf(platforms > 1) AS tied_timestamp_platform_conflicts,
    countIf(countries > 1) AS tied_timestamp_country_conflicts,
    countIf(contents > 1) AS tied_timestamp_content_conflicts,
    countIf(stop_events > 0 AND start_events > 0) AS tied_stop_start_conflicts
FROM
(
    SELECT
        video_session_id,
        event_timestamp,
        count() AS events_at_timestamp,
        uniqExact(platform) AS platforms,
        uniqExact(country) AS countries,
        uniqExact(content_id) AS contents,
        countIf(event_type IN ('AppBackgrounded', 'VideoSessionEnd') OR event = 'pause') AS stop_events,
        countIf(event_type IN ('AppForegrounded', 'VideoPlay') OR event = 'resume') AS start_events
    FROM
    (
        SELECT DISTINCT content_id, video_session_id, user_id, event_type, event, event_timestamp, platform,
            app_version, country, audio_language, subtitle_language, player_version, session_start_epoch
        FROM ev_raw
    )
    GROUP BY video_session_id, event_timestamp
)
FORMAT PrettyCompact;

SELECT countIf(event_type = 'VideoHeartbeat' AND event_timestamp > terminal_at) AS heartbeats_after_terminal
FROM
(
    SELECT *, minIf(event_timestamp, event_type = 'VideoSessionEnd') OVER (PARTITION BY video_session_id) AS terminal_at
    FROM ev_raw
)
WHERE terminal_at != toDateTime64(0, 3)
FORMAT PrettyCompact;

SELECT
    countIf(first_event < declared_start) AS sessions_with_event_before_declared_start,
    countIf(declared_start_values > 1) AS sessions_with_declared_start_drift,
    countIf(dateDiff('hour', first_event, last_event) >= 24) AS sessions_spanning_at_least_one_day,
    max(dateDiff('second', first_event, last_event)) AS max_session_span_seconds
FROM
(
    SELECT video_session_id, min(event_timestamp) AS first_event, max(event_timestamp) AS last_event,
        min(session_start_epoch) AS declared_start, uniqExact(session_start_epoch) AS declared_start_values
    FROM ev_raw
    GROUP BY video_session_id
)
FORMAT PrettyCompact;

WITH toDateTime64({cutoff:String}, 3) AS cut_at
SELECT
    count() AS sessions_started_before_cutoff,
    countIf(ends_before_cutoff = 0) AS open_at_cutoff,
    countIf(heartbeats_before_cutoff > 0 AND ends_before_cutoff = 0) AS open_with_activity
FROM
(
    SELECT
        video_session_id,
        countIf(event_timestamp <= cut_at AND event_type = 'VideoSessionStart') AS starts_before_cutoff,
        countIf(event_timestamp <= cut_at AND event_type = 'VideoSessionEnd') AS ends_before_cutoff,
        countIf(event_timestamp <= cut_at AND event_type = 'VideoHeartbeat') AS heartbeats_before_cutoff
    FROM ev_raw
    GROUP BY video_session_id
    HAVING starts_before_cutoff > 0
)
FORMAT PrettyCompact;
