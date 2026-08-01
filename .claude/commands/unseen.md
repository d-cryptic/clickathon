---
description: Run the unseen-day dataset end to end through the pipeline and package the evidence.
---
The graded run. **No pipeline evidence, no credit** — hand-computed answers score nothing.

1. Load the unseen file with `tools/load.sh <path>` into a **fresh partition**; do not drop existing data.
2. Rebuild intervals and the serving layer incrementally. Record whether it was incremental or a
   rebuild — "update handling" is an explicit scoring criterion.
3. Run `/reconcile` on the new day. Do not proceed on a non-zero delta.
4. Run `/bench` and capture latencies.
5. Package into `evidence/unseen/`: the answers, the query latencies, the `system.query_log` rows
   proving they ran (filter on `log_comment`), and the ClickStack trace of the ingestion.
6. Sanity-check for the traps: any sessions still open at the end of the day? any heartbeat gaps
   larger than seen in the training file? any new platform/country values? Report them explicitly.

Tag the commit `unseen-day-run-<timestamp>`.
