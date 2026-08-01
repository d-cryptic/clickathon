-- ============================================================================
-- 20_views.sql — read-only views for charting and ad-hoc reads.
--
-- These exist because a chart tool cannot read an AggregateFunction column.
-- cc_minute_stateless.active_state is AggregateFunction(uniqExact, String):
-- correct for storage and merging, but HyperDX (or any BI tool) needs a plain
-- number. The merge belongs in a view, once, rather than being re-typed into
-- every chart definition where it can be got subtly wrong.
--
-- Views are free: no storage, no merge cost, and re-running this file is
-- idempotent, so it is safe on every boot and every target.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Minute-grain concurrency from the SESSION-INDEPENDENT (stateless) model.
--
-- Named _stateless deliberately: `v_concurrency_minute` is reserved for the
-- accurate gap-based model (TODOS H3). Two models, two views, and the
-- comparison between them is an explicit deliverable — so they must never be
-- silently swapped behind one name.
--
-- Grain: one row per (minute, platform, country, content_id). Summing
-- `concurrent` across dimensions is NOT valid — a session active on two
-- content_ids would be counted twice. Filter, then read; do not aggregate up.
-- Use v_concurrency_minute_total for the all-dimensions curve.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_concurrency_minute_stateless AS
SELECT
    minute,
    platform,
    country,
    content_id,
    uniqExactMerge(active_state) AS concurrent
FROM cc_minute_stateless
GROUP BY minute, platform, country, content_id;

-- ---------------------------------------------------------------------------
-- The headline curve: total concurrency per minute, all dimensions collapsed.
--
-- This re-merges the states rather than summing the per-dimension view, which
-- is the whole point — uniqExactMerge over the underlying states deduplicates a
-- session that appears under several content_ids, and SUM() would not.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_concurrency_minute_total AS
SELECT
    minute,
    uniqExactMerge(active_state) AS concurrent
FROM cc_minute_stateless
GROUP BY minute;
