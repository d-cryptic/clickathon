# upstream/ — the organiser's spec, verbatim

> **Summary:** Byte-for-byte copies of the three spec files from
> [sidagarwal04/click-a-thon-2026](https://github.com/sidagarwal04/click-a-thon-2026/tree/main/SonyLiv),
> synced by `tools/fetch_data.sh`. **Never edit these** — they are the contract, and a diff against
> upstream must mean upstream changed, not that we tidied them. `PROBLEM_STATEMENT.md` is
> byte-identical to `docs/PROBLEM.md`. The other two were NOT read until 2026-08-01 and between them
> they carry requirements the build had been missing: content-metadata enrichment, user-level
> concurrency, ten filter dimensions, and time-window trend.

## Why this directory exists

`tools/fetch_data.sh` originally pulled only the two CSVs. The spec lives in the same upstream folder,
so we built for a day and a half against one of three files. The script now syncs all three and warns
loudly if a file changed since the last sync.

## What the two unread files added

| Source | Requirement | State |
|---|---|---|
| README_START_HERE.md | "Enrich events with content metadata" — join `content_dim` | **was missing** — `content_dim` was loaded but never referenced |
| README_START_HERE.md | **Content-level concurrency** by title / video_type / category | **was missing** |
| README_START_HERE.md | **Time-window trend** — rolling/fixed windows, watermarking, refresh latency | partially — watermark measured, windows not built |
| dataset_details.md | **User-level concurrency** "will be derived from" `user_id` | **was missing** — `user_id` carried into `session_intervals`, never aggregated |
| dataset_details.md | Ten filter dimensions | `session_intervals` carried three |
| dataset_details.md | "the solution should work even if the number of dimensions increases" | design constraint, not a feature |

## Where the organiser's doc contradicts the shipped data

`dataset_details.md` says the heartbeat "is currently passed every 1 minute". Measured on the real
file (ADR 0007): `VideoHeartbeat` is bursty telemetry at **4.72 events/min**, inter-arrival p50 **0s**,
p90 40s, p99 49s — not a 1-minute beat. Our model follows the data, not the doc. This is a **mentor
question**, not just a fix: if the graders' ground truth assumed a 1-minute beat, the gap matters.
