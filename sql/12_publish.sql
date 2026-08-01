-- ============================================================================
-- 12_publish.sql — CONTINUOUS PUBLICATION. The state the finalizer runs on.
--
-- README_START_HERE step 4 is "Publish continuously updated aggregates for
-- downstream consumers". Until now the honest answer was "by recomputing":
-- tools/build-model.sh TRUNCATEs session_intervals and cc_minute_delta and
-- rebuilds both from all of ev_raw. This file is the state that lets
-- tools/publish.sh do it INCREMENTALLY instead — see ADR 0013.
--
-- The mechanism in one paragraph. An incremental materialized view on ev_raw
-- writes, per insert block, the set of sessions that block touched, stamped
-- with INGEST time (`session_dirty`). A finalizer claims everything marked
-- since its cursor, re-derives ONLY those sessions from ev_raw, appends the
-- NEGATION of their currently-published deltas and then their new deltas
-- (ADR 0006 correction-by-diff), promotes the new intervals and advances the
-- cursor. Nothing is truncated and nothing is rebuilt.
--
-- WHY THIS IS EXACT, and not an approximation. A session's contribution to
-- cc_minute_delta is a pure function of THAT SESSION'S intervals alone:
-- sql/40_deltas.sql groups by video_session_id, merges that session's runs,
-- hour-clips them, and only then sums into the (minute, dims) grain. No
-- cross-session term exists. So for a touched set S,
--
--     published(S)  :=  deltas(intervals_old(S))
--     wanted(S)     :=  deltas(intervals_new(S))
--
-- and appending `wanted(S) - published(S)` into an AggregatingMergeTree of
-- SimpleAggregateFunction(sum, Int64) converges on exactly the value a full
-- rebuild would have written. Sessions outside S are untouched and their terms
-- are unchanged. This is a rebuild — of one session at a time.
--
-- WHY THE WATERMARK IS NO LONGER A GATE. ADR 0004 split serving into a sealed
-- tier behind a watermark W and a hot tier in front of it, because a straggler
-- older than W had no path. Correction-by-diff IS that path, and it does not
-- care how old the straggler is: a late event marks its session dirty, the next
-- batch re-derives that session in full and diffs. W survives only as a
-- FRESHNESS LABEL (v_cc_publish_lag below), not as a control knob. See ADR 0013.
--
-- SAFE ON A FRESH DATABASE, AND NO REBUILD TO CATCH UP. Every object here is
-- CREATE ... IF NOT EXISTS and holds no data. On a fresh database the first
-- bulk load fires mv_session_dirty, every session is marked, and the first
-- publish run derives all of them — the initial build and every later update
-- run down the SAME code path, so there is no bootstrap special case to get
-- wrong. On an ALREADY-BUILT database nothing is marked, the cursor starts at
-- the current ingest position, and the first run has nothing to do: applying
-- this file to a populated service costs one DDL round trip and does NOT
-- trigger a re-derivation of history.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- session_dirty — the change log. One row per (session, insert block).
--
-- This is the piece that makes the pipeline event-driven rather than
-- scheduled-scan. ADR 0006 suggested the finalizer find stragglers by
-- "comparing the max event timestamp it has processed per session against what
-- it processed previously", which is a GROUP BY over all of ev_raw on every
-- run — O(history) work per batch, i.e. exactly the "only works at hackathon
-- size" shape the problem statement calls out. An incremental MV sees only the
-- current insert block, which is precisely the right amount of information:
-- whatever just arrived is what needs re-deriving.
--
-- `marked_at` is INGEST time (now64(3) at insert), NOT event time. That
-- distinction is the whole point — a straggler carrying an event_timestamp
-- from 40 minutes ago still gets a marked_at of now, so the cursor finds it.
--
-- ORDER BY (marked_at, ...) so the finalizer's `WHERE marked_at > cursor` is a
-- primary-key prefix range and costs granules, not a scan.
--
-- min/max_event_ts are carried so the finalizer can bound its read of ev_raw
-- by event time as well as by session id — see tools/publish.sh, and note the
-- completeness argument there: it is not a heuristic.
--
-- TTL 7 days: this is a queue, not history. The runs log below is the audit
-- trail. Nothing reads session_dirty behind the committed cursor.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS session_dirty
(
    marked_at        DateTime64(3),
    video_session_id String,
    min_event_ts     DateTime64(3),
    max_event_ts     DateTime64(3),
    events           UInt32
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(marked_at)
ORDER BY (marked_at, video_session_id)
TTL toDateTime(marked_at) + INTERVAL 7 DAY
SETTINGS min_bytes_for_wide_part = 0;

-- Fires on every insert into ev_raw — the bulk load, the unseen day, a single
-- replayed straggler. GROUP BY collapses the block to one row per session, so
-- a 905,558-row load writes ~10,866 rows here, not 905,558.
--
-- now64(3) is constant-folded per query, so it is legal alongside GROUP BY and
-- every session in one block shares one marked_at. Verified on Cloud 26.2.1.525
-- before this file was written; two loads a second apart produce two distinct
-- marked_at values, which is what the cursor needs.
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_session_dirty TO session_dirty AS
SELECT
    now64(3)             AS marked_at,
    video_session_id,
    min(event_timestamp) AS min_event_ts,
    max(event_timestamp) AS max_event_ts,
    toUInt32(count())    AS events
FROM ev_raw
GROUP BY video_session_id;


-- ---------------------------------------------------------------------------
-- cc_publish_batch — the sessions one run has claimed, frozen.
--
-- Frozen deliberately. The run's four heavy statements must all see the SAME
-- session set; reading `session_dirty WHERE marked_at > cursor` four times
-- would let an insert landing mid-run into some statements and not others, and
-- the negation would then not match the emission. Claim once, then join.
--
-- lo_event_ts/hi_event_ts are the per-session read window (see publish.sh).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cc_publish_batch
(
    run_id           UInt64,
    video_session_id String,
    lo_event_ts      DateTime64(3),
    hi_event_ts      DateTime64(3)
)
ENGINE = MergeTree
PARTITION BY run_id
ORDER BY (run_id, video_session_id)
TTL toDateTime(fromUnixTimestamp(intDiv(run_id, 1000))) + INTERVAL 7 DAY
SETTINGS min_bytes_for_wide_part = 0;


-- ---------------------------------------------------------------------------
-- cc_publish_consumed — which INSERTs the finalizer has already digested.
--
-- A scalar timestamp cursor alone is not enough, and the first run of
-- tools/publish-test.sh proved it: with a cursor plus a safety lookback, every
-- run re-claimed the whole of the previous run's batch, because the previous
-- batch's marked_at sits exactly ON the cursor. 6,659 sessions were re-derived
-- to absorb 5. Harmless — re-publishing an unchanged session appends
-- -deltas(X) + deltas(X) = 0 — but it turns an incremental update back into a
-- rebuild, which is the entire thing this design exists to avoid.
--
-- now64(3) is constant-folded per QUERY, so every row an INSERT produces here
-- carries ONE marked_at: marked_at identifies the insert, not the block.
-- (Measured: a 458,477-row load landing in 7 parts produced exactly 1 distinct
-- marked_at.) That makes exact set-bookkeeping cheap — one row per insert,
-- not per session and not per event — and it removes the redundant work
-- entirely rather than bounding it.
--
-- Pairs with the SETTLE rule in tools/publish.sh: a marking is only eligible
-- once it is PUBLISH_SETTLE_S old, so an insert still committing cannot be
-- half-consumed and then marked done.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cc_publish_consumed
(
    marked_at DateTime64(3),
    run_id    UInt64
)
ENGINE = ReplacingMergeTree
ORDER BY marked_at
TTL toDateTime(marked_at) + INTERVAL 7 DAY
SETTINGS min_bytes_for_wide_part = 0;


-- ---------------------------------------------------------------------------
-- cc_publish_runs — the write-ahead log, the cursor, and the audit trail.
--
-- One row per PHASE per run, appended as that phase completes. Three jobs:
--
--   1. THE CURSOR.  max(cursor_to) over committed runs. Nothing else stores it.
--   2. CRASH RECOVERY.  A run's four heavy statements are not one transaction.
--      The phase markers say which ones landed, so a resumed run continues
--      instead of restarting — restarting would negate a second time.
--      Belt and braces: each heavy statement also carries
--      insert_deduplication_token = '<run_id>:<phase>', so a replay of a
--      statement that DID land is dropped by the server rather than doubled.
--      Verified on SharedAggregatingMergeTree before this file was written.
--   3. OBSERVABILITY.  Batch size, row counts and per-phase wall clock, which
--      is what v_cc_publish_lag and ClickStack read.
--
-- Phases, in order:
--   claimed   the batch table is written and the read window is known
--   negated   -deltas(intervals_old(batch)) appended to cc_minute_delta
--   derived   intervals_new(batch) inserted into session_intervals @ build_version
--   pruned    intervals_old(batch) removed (build_version < this run's)
--   emitted   +deltas(intervals_new(batch)) appended to cc_minute_delta
--   committed cursor advanced; the run is durable
--
-- WHY `pruned` EXISTS. session_intervals is ReplacingMergeTree keyed
-- (video_session_id, interval_start), which replaces a key but cannot delete
-- one. A re-derivation can legitimately make an interval VANISH — a straggler
-- landing inside a gap merges two runs into one, so the second run's start key
-- no longer exists. Without the prune, FINAL keeps that orphan for ever, the
-- interval-expansion views over-count, and — worse — the NEXT run's negation
-- would negate deltas that were never published, so the error would compound
-- rather than sit still. This is the same class of bug as the
-- ReplacingMergeTree(interval_end) defect in sql/10_intervals.sql: a merge rule
-- that assumes re-derivation can only ever add.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cc_publish_runs
(
    run_id       UInt64,
    phase        LowCardinality(String),
    at           DateTime64(3),
    cursor_from  DateTime64(3),
    cursor_to    DateTime64(3),
    sessions     UInt32,
    rows_written UInt64,
    elapsed_ms   UInt32,
    note         String
)
ENGINE = MergeTree
ORDER BY (run_id, at)
SETTINGS min_bytes_for_wide_part = 0;


-- ---------------------------------------------------------------------------
-- v_cc_publish_lag — REFRESH LATENCY, which is the third column of the
-- statement's core-aggregation table and the one v_cc_watermark could not
-- answer.
--
-- v_cc_watermark (sql/85_windows.sql) reports EVENT-time staleness: how far the
-- newest sealed minute is from the newest event. That is the right metric for a
-- batch-rebuilt model, and it has a documented sign trap — a caught-up model
-- reads NEGATIVE because TAIL_S pushes the sealed minute past the last event.
--
-- This view reports INGEST-time staleness instead: how long ago the newest
-- arrival that the serving layer has actually absorbed came in. It is the
-- number an operator wants ("are the aggregates current?") and it cannot go
-- negative. The two are complements, not rivals — keep both.
--
-- pending_sessions is the queue depth: sessions marked dirty that the serving
-- layer has not yet re-derived. Zero means the aggregates are exact as of
-- publish_cursor. It is the alerting signal, because publish_lag_s alone looks
-- healthy on an idle stream where nothing has arrived to be late.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_cc_publish_lag AS
WITH
    (SELECT max(cursor_to) FROM cc_publish_runs WHERE phase = 'committed') AS cursor_,
    (SELECT max(marked_at)  FROM session_dirty)                            AS ingest_wm,
    (SELECT max(run_id)     FROM cc_publish_runs WHERE phase = 'committed') AS last_run
SELECT
    cursor_    AS publish_cursor,      -- ingest position the serving layer is exact as of
    ingest_wm  AS ingest_watermark,    -- newest arrival the change log has seen

    -- POSITIVE = the finalizer is behind by this many seconds of ARRIVALS.
    -- Never negative, unlike v_cc_watermark.sealed_lag_s.
    greatest(0, dateDiff('second', cursor_, ingest_wm))       AS publish_lag_s,

    -- Queue depth. The signal that matters: a lag of 0 on an idle stream is
    -- not the same as a lag of 0 on a busy one. Counted against the digested
    -- SET, not against the cursor — an insert whose marking ties the cursor is
    -- pending or not depending on whether it was consumed, and only
    -- cc_publish_consumed knows which.
    (SELECT uniqExact(video_session_id) FROM session_dirty
      WHERE marked_at NOT IN (SELECT marked_at FROM cc_publish_consumed))
                                                              AS pending_sessions,

    last_run                                                  AS last_committed_run,
    (SELECT sum(elapsed_ms) FROM cc_publish_runs
      WHERE run_id = last_run)                                AS last_run_ms,
    (SELECT sessions FROM cc_publish_runs
      WHERE run_id = last_run AND phase = 'committed')        AS last_run_sessions,

    -- Has a run started and not finished? Non-zero means a crashed or in-flight
    -- run; tools/publish.sh resumes it rather than starting a new one.
    (SELECT count() FROM (
        SELECT run_id FROM cc_publish_runs
        GROUP BY run_id HAVING countIf(phase = 'committed') = 0))          AS runs_in_flight
FROM system.one;
