# upstream/ — organiser contracts, vendored verbatim

> **Summary:** This directory contains verbatim-content copies of the four SonyLIV problem-package
> contracts and the two current SonyLIV/common submission contracts.
> The problem package was verified against `sidagarwal04/click-a-thon-2026@c1e1c69` and the
> submission package against `sidagarwal04/click-a-thon-26-submissions@c446938` on 2026-08-02.
> `unseen_spec.md` adds `video_resolution` and `show_name`; both are mandatory filter dimensions.
> Never edit the vendored files: re-sync them with `tools/fetch_data.sh`, inspect every diff, then
> update implementation and project docs in the same change.

## Contract inventory

| Local file | Upstream source | What it controls |
|---|---|---|
| `PROBLEM_STATEMENT.md` | SonyLiv/PROBLEM_STATEMENT.md | task, foreground-only semantics, benchmark and unseen evidence |
| `README_START_HERE.md` | SonyLiv/README_START_HERE.md | expected pipeline, aggregation and integration surfaces |
| `dataset_details.md` | SonyLiv/dataset_details.md | original field names and business meaning |
| `unseen_spec.md` | SonyLiv/unseen_data/spec.md | official 7M-row release and the two new filter columns |
| `SONYLIV_SUBMISSION_GUIDELINES.md` | submission repository | SonyLIV curve/filter/UI evidence |
| `SUBMISSIONS_README.md` | submission repository root | team folder, hosted demo, video, architecture, deck and PR rules |

`tools/fetch_data.sh` fetches all six files and warns when either source changes. The data downloader
still checksum-pins the original two CSVs; the official unseen files are Drive-hosted and their
observed hashes are recorded in the current Codex validation report.

## Requirements that are easy to miss

- User concurrency is derived from `user_id`, separately from session concurrency.
- Content metadata is joined at query time and title/type/category/show filters must not drop orphans.
- Every dataset dimension must filter the concurrency curve in the product UI.
- More dimensions may arrive; unknown columns need a lossless landing path and a generic fallback,
  while measured hot dimensions should be promoted to named serving paths.
- The official unseen submission needs answers, latencies, and query-log or trace evidence from the
  actual pipeline. A locally reconstructed benchmark is not a substitute.
- The final package needs source, README with hosted demo link, architecture, a 2–3 minute video,
  pitch-deck PDF, self-contained team folder, and `[Submission] Team Name` pull request.
- Because this project uses ClickStack, the package must also commit its deployment and OTel wiring,
  a redacted `.env.example`, name the ClickHouse service/tables receiving telemetry, include the
  dashboards/searches actually used in the README, and walk through them live in the hosted demo
  and video. Screenshots are required supporting evidence, but are not proof by themselves.

## Source/data contradictions to keep visible

The original dictionary says heartbeats arrive every minute. The original file's useful cadence is
closer to 40 seconds and contains same-second bursts; the official unseen file also has a strong
40-second mode. The model therefore uses one declared gap policy rather than learning a threshold
from each batch. Explicit background/foreground events are not guaranteed, but the task still says
background time must be excluded. That semantic choice remains separate from heartbeat-only versus
all-activity liveness and must not be inferred from self-reconciliation.
