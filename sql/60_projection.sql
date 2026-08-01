-- sql/60_projection.sql — session-ordered PROJECTION on ev_raw
--
-- Summary: adds `proj_by_session`, a normal PROJECTION over ev_raw ordered by
-- (video_session_id, event_timestamp). Recovers point-lookup-by-session performance for
-- the finalizer and straggler/late-arrival paths WITHOUT touching the base table's sort
-- key. Run after sql/00_schema.sql and after ev_raw is loaded. Idempotent.
--
-- WHY (see docs/adr/0002-order-by-time-bucket-then-platform.md):
--   ADR 0002 moved ev_raw's ORDER BY from (video_session_id, event_timestamp) to
--   (toStartOfHour(event_timestamp), platform, video_session_id, event_timestamp) — measured
--   17.3x better on the dashboard shape, because a 64-char near-unique hash in the key prefix
--   lets the sparse index skip nothing (rule `schema-pk-cardinality-order`, impact CRITICAL).
--   That decision stands and is NOT reverted here.
--
--   ADR 0002's own Consequences section names the remedy for the access pattern it gave up:
--     "If a 'single session lookup' access pattern ever becomes hot, add a PROJECTION ordered
--      by video_session_id rather than reverting the key."
--   That pattern IS hot for us: the interval finalizer and the late-arrival/straggler path both
--   fetch every event of a *named* set of sessions. Under ADR 0002's key those queries can only
--   prune the granules where (hour, platform) happens to stay constant across a granule run —
--   measured 31/115 granules, 225,619 of 905,558 rows for a single-session lookup.
--
--   A projection is a second, independently-sorted copy of the data stored inside each part.
--   The query planner picks it automatically (optimize_use_projections=1); no query is rewritten.
--   Partition pruning still applies, and the base table's dashboard performance is untouched.
--
-- COST: the projection is a full second copy of every column, sorted by a high-entropy hash,
--   so it compresses far worse than the base table. Measure before keeping it — see the
--   measurement table in the H4 worksheet. Storage is the trade; reads are the win.

ALTER TABLE sonyliv.ev_raw
    ADD PROJECTION IF NOT EXISTS proj_by_session
    (
        SELECT *
        ORDER BY (video_session_id, event_timestamp)
    );

-- Rewrites every active part to build the projection. On 905K rows this is seconds, but it IS
-- a mutation: confirm it drained before trusting any "after" measurement.
--   SELECT * FROM system.mutations
--   WHERE database = 'sonyliv' AND table = 'ev_raw' AND NOT is_done;
ALTER TABLE sonyliv.ev_raw MATERIALIZE PROJECTION proj_by_session;
