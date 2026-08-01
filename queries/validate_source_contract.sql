WITH
    source_events AS
    (
        SELECT DISTINCT
            content_id,
            video_session_id,
            user_id,
            event_type,
            event,
            event_timestamp,
            platform,
            app_version,
            country,
            audio_language,
            subtitle_language,
            player_version,
            session_start_epoch
        FROM ev_raw
    ),
    session_shape AS
    (
        SELECT
            video_session_id,
            min(event_timestamp) AS first_event_at,
            min(session_start_epoch) AS declared_start_at,
            uniqExact(session_start_epoch) AS incarnations,
            countIf(event_type = 'VideoSessionEnd') AS terminal_events
        FROM source_events
        GROUP BY video_session_id
    ),
    tied_dimensions AS
    (
        SELECT count() AS conflicts
        FROM
        (
            SELECT video_session_id, event_timestamp
            FROM source_events
            GROUP BY video_session_id, event_timestamp
            HAVING
                uniqExact(platform) > 1
                OR uniqExact(country) > 1
                OR uniqExact(content_id) > 1
        )
    ),
    violations AS
    (
        SELECT
            (SELECT count() FROM ev_raw WHERE video_session_id = '' OR user_id = '') AS empty_identity,
            (SELECT count() FROM ev_raw WHERE event_timestamp = toDateTime64(0, 3) OR session_start_epoch = toDateTime64(0, 3)) AS epoch_timestamp,
            (SELECT count() FROM ev_raw WHERE event_timestamp > ingested_at + toIntervalMinute(5)) AS future_event_clock_skew,
            (SELECT count() FROM ev_raw WHERE event_type NOT IN ('AppBackgrounded', 'AppForegrounded', 'VideoError', 'VideoHeartbeat', 'VideoPlay', 'VideoSessionEnd', 'VideoSessionStart')) AS unknown_event_type,
            (SELECT count() FROM ev_raw AS r LEFT JOIN content_dim AS c ON r.content_id = c.content_id WHERE c.content_id IS NULL) AS missing_content_dimension,
            (SELECT count() FROM (SELECT content_id FROM content_dim GROUP BY content_id HAVING uniqExact(tuple(title, video_type, category)) > 1)) AS conflicting_content_dimension,
            (SELECT count() FROM session_shape WHERE first_event_at < declared_start_at) AS events_before_declared_start,
            (SELECT count() FROM session_shape WHERE incarnations > 1) AS reused_video_session_id,
            (SELECT conflicts FROM tied_dimensions) AS tied_dimension_conflicts
    )
SELECT
    empty_identity,
    epoch_timestamp,
    future_event_clock_skew,
    unknown_event_type,
    missing_content_dimension,
    conflicting_content_dimension,
    events_before_declared_start,
    reused_video_session_id,
    tied_dimension_conflicts,
    (SELECT count() - uniqExact(tuple(content_id, video_session_id, user_id, event_type, event, event_timestamp, platform, app_version, country, audio_language, subtitle_language, player_version, session_start_epoch)) FROM ev_raw) AS retry_payload_duplicates,
    (SELECT count() FROM session_shape WHERE terminal_events > 1) AS duplicate_terminal_sessions,
    throwIf(
        empty_identity + epoch_timestamp + future_event_clock_skew + unknown_event_type + missing_content_dimension + conflicting_content_dimension
        + events_before_declared_start + reused_video_session_id + tied_dimension_conflicts != 0,
        'source contract violation: inspect reported hard-failure counts before materialization'
    ) AS contract_assertion
FROM violations
FORMAT PrettyCompact;
