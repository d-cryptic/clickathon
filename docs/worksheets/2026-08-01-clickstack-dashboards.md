# Worksheet — 2026-08-01 · hosted ClickStack dashboard build-out

> **Summary:** Audited the hosted HyperDX (11 sources / 1 dashboard / 4 saved searches / 0 alerts),
> found the dimensional tiles arithmetically wrong (max-combo: showed 285 where truth is 1,837) and
> one orphan saved search; added 13 sources + 5 dashboards (6 total), all provisioned and CONVERGED
> by tools/clickstack-cloud.sh, every key tile verified by executing it through HyperDX's own query
> path. New chart-only views in sql/87_viz.sql (naive span, session-minutes drilldown, per-dim
> curves); reconcile gate re-run after applying: 17,028 minutes, 0 mismatched, peak 2,917.
> Evidence: evidence/clickstack-dashboards.txt · fallback: docs/artifacts/…clickstack-dashboards.html.

## Goal

MORE dashboards on the CLOUD-HOSTED ClickStack (the 25% OSS-integration rubric surface): headline
model comparison incl. naive span, filterable drilldown on all 7 dimensions, content, time-window
trend, pipeline health, query cost. Audit first; verify against the live service; evidence for the
deck; reproducible from a script.

## Decisions (why, not just what)

1. **Rebased this branch onto `dev` before any model claim.** First reconcile run FAILED (truth
   2,887 vs serving 2,917): the service runs dev's ADR 0009 model, this worktree was cut from an
   older base whose `sql/90_reconcile.sql` predated the same-second-resume fix. No local commits
   existed, so `git reset --hard dev`.
2. **Drilldown = session-minute grain + `count_distinct`** (`v_session_minutes`), because it is the
   only aggregation correct under ANY filter combination — a delta view needs its running sum
   rebuilt after the filter, which no chart builder can express. At 1-min zoom it IS concurrency
   (verified 2,917/2,844 at the peak minute).
3. **Breakdown tiles read per-dimension views** (`v_cc_by_*`): sum deltas at that grain, THEN
   running-sum, so `max()` is a genuine peak at any zoom. Replaces the max-combo tiles.
4. **Pipeline health on hosted is cloud-native** — the Cloud service has no OTLP path (no `otel_*`
   tables, verified), so watermark comes from `v_cc_watermark` (source timestamped `now()`), build
   stages from `system.query_log` with `internal/pipelinehealth`'s exact filters. The OTLP twin
   stays local (docs/OBSERVABILITY.md).
5. **No alerts, deliberately** — frozen dataset: a threshold alert never fires or fires forever.

## State: DONE, verified

- 6 dashboards live; script run 4×: creates once, then "updated" — idempotent, no duplicates.
- Verified through HyperDX's query path: drilldown 2,917/2,844 @ 10:56 · naive 3,708 @ 10:56 and
  3,743 @ 10:59 · rolling peak_5m holds 2,917 · watermark −116 s under a today-range · reconcile
  runs + bytes-read tiles render today's operator activity.
- Found & fixed live: user views renamed to `concurrent_users` on dev → old user tiles were
  silently broken; sources PUT-patched, script corrected, tile re-verified (2,844).
- `make reconcile` (cloud): PASS, 17,028 / 0 / peak 2,917 — after sql/87_viz.sql applied.

## Open / next

- Screenshots of the live dashboards for the deck need a human (console SSO) — URLs + ranges in
  docs/CLICKSTACK.md; offline fallback committed at docs/artifacts/2026-08-01-clickstack-dashboards.html
  (regen: tools/clickstack-artifact.sh).
- Dashboard default time range is not settable via API — pre-demo human step, every time.
- Tile ids regenerate on PUT; don't deep-link tiles in the deck, link dashboards.

## How to verify

`tools/clickstack-cloud.sh` (idempotent) · `TARGET=cloud tools/reconcile.sh` ·
clickstack MCP `query_tile` on any tile listed in evidence/clickstack-dashboards.txt.
