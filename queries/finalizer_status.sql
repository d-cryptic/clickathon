-- One-row operational health for the finalizer. Alert on source lag, pending
-- runs, and correction-state growth; raw ingest health alone is insufficient.

WITH
    latest_published AS
    (
        SELECT
            argMax(source_high_watermark, finalizer_run_log.run_sequence) AS source_high_watermark,
            argMax(event_watermark, finalizer_run_log.run_sequence) AS event_watermark,
            argMax(model_version, finalizer_run_log.run_sequence) AS model_version,
            max(finalizer_run_log.run_sequence) AS run_sequence,
            max(recorded_at) AS published_at
        FROM finalizer_run_log
        WHERE phase = 'published'
    ),
    raw_bounds AS
    (
        SELECT max(ingested_at) AS raw_high_watermark, max(event_timestamp) AS max_event_time
        FROM ev_raw
    ),
    pending AS
    (
        SELECT count() AS pending_runs
        FROM
        (
            SELECT run_id
            FROM finalizer_run_log
            GROUP BY run_id
            HAVING max(phase) IN ('prepared', 'staged')
        )
    ),
    correction_state AS
    (
        SELECT count() AS correction_markers
        FROM
        (
            SELECT
                video_session_id,
                platform,
                country,
                content_id,
                minute,
                argMax(correction_delta, run_sequence) AS correction_delta
            FROM session_delta_correction_stage
            WHERE run_id IN
            (
                SELECT run_id
                FROM finalizer_run_log
                GROUP BY run_id
                HAVING max(phase) = 'published'
            )
            GROUP BY video_session_id, platform, country, content_id, minute
            HAVING correction_delta != 0
        )
    ),
    latest_tail AS
    (
        SELECT
            max(exact_tail_run_log.run_sequence) AS tail_run_sequence,
            argMax(finalizer_run_sequence, exact_tail_run_log.run_sequence) AS finalizer_run_sequence,
            argMax(event_watermark, exact_tail_run_log.run_sequence) AS event_watermark,
            argMax(tail_until, exact_tail_run_log.run_sequence) AS tail_until,
            argMax(staged_rows, exact_tail_run_log.run_sequence) AS staged_rows,
            max(recorded_at) AS published_at
        FROM exact_tail_run_log
        WHERE phase = 'published'
    )
SELECT
    latest_published.run_sequence,
    latest_published.model_version,
    latest_published.published_at,
    latest_published.source_high_watermark,
    raw_bounds.raw_high_watermark,
    dateDiff('second', latest_published.source_high_watermark, raw_bounds.raw_high_watermark) AS source_checkpoint_lag_seconds,
    latest_published.event_watermark,
    raw_bounds.max_event_time,
    dateDiff('second', latest_published.event_watermark, raw_bounds.max_event_time) AS configured_watermark_seconds,
    latest_tail.tail_run_sequence,
    latest_tail.finalizer_run_sequence AS tail_finalizer_sequence,
    latest_tail.event_watermark AS tail_watermark,
    latest_tail.tail_until AS tail_until,
    latest_tail.staged_rows AS tail_staged_rows,
    latest_tail.published_at AS tail_published_at,
    toUInt8(latest_tail.finalizer_run_sequence = latest_published.run_sequence) AS tail_matches_current_finalizer,
    pending.pending_runs,
    correction_state.correction_markers
FROM latest_published
CROSS JOIN raw_bounds
CROSS JOIN pending
CROSS JOIN correction_state
CROSS JOIN latest_tail;
