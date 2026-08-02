# <TEAM NAME>

<!-- ─────────────────────────────────────────────────────────────────────────
  FILL-IN CHECKLIST — every remaining human step, listed first on purpose.
  Delete this comment block once all items are done.

  [ ] Replace <TEAM NAME> above (and rename the team folder to match — the
      folder name at the repo root IS the team identifier)
  [ ] Fill in ## Team Members (names + GitHub handles)
  [ ] Fill in ## Hosted Demo with a live URL — must show the concurrency
      curve and working filters (a screenshot is explicitly insufficient)
  [ ] Fill in ## Demo Video with a 2–3 minute recorded video URL — must
      show the curve, filters, and ClickStack live
  [ ] Embed real ClickStack dashboard screenshots in § ClickStack
      (the committed evidence/clickstack/dashboard-preview.png is a
      generated preview, not a live capture)
  [ ] Eyeball deck/final/pitch-deck.pdf (13 pages rendered from 12 slides —
      check the one spillover page looks intentional)
  [ ] Secret-scan before publishing (see the note at the bottom)
  [ ] Open the PR titled exactly: [Submission] <TEAM NAME>
───────────────────────────────────────────────────────────────────────── -->

## Track

SonyLIV — *"Counting the crowd: foreground-only concurrency at streaming scale."*

## Project

**Foreground-only concurrency at streaming scale** — counts how many viewers are
*actively watching* each minute, excluding backgrounded, paused and heartbeat-missing
time, and proves it: on the official unseen file (7,000,000 events) the pipeline
reconciled **3,201,716 minutes against raw events with zero mismatches**.

## Team Members

- <Name> ([@<github-handle>](https://github.com/<github-handle>))
- <Name> ([@<github-handle>](https://github.com/<github-handle>))

## What it does

Count viewers **actively watching** at each minute. The naive reading — a session is
"on" from its first event to its last — overcounts, because a backgrounded or paused
session is still a session. On the sample data, **33.6% of apparent watch time was
backgrounded or paused**.

Two signals are needed, not one, and this is the core modelling insight:

- **Heartbeat gaps catch backgrounding.** Heartbeats effectively stop while an app is
  backgrounded (0.047/min, against 4.72/min while active).
- **Explicit pause/resume is required for pausing**, because heartbeats *survive* a
  pause (0.756/min). Gaps alone therefore cannot find paused time — it has to be
  excluded explicitly.

A model built on gaps alone silently counts every paused viewer as watching. Full
reasoning: [`docs/EXPLAINER.md`](docs/EXPLAINER.md) and
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

### Results on the official unseen file

| | |
|---|---|
| Events | 7,000,000 |
| Landing | lossless — `ev_landing` 7,000,000 = `ev_raw` 7,000,000 + 0 cast rejects |
| Semantically quarantined | 3 (timestamps out of range) |
| Output dates | 102, built as Cloud-legal chunks of 64 + 38 |
| Reconciliation | **3,201,716 minutes compared · 0 mismatched · max_abs_diff 0** |
| **Peak concurrency** | **23,324** @ 2026-07-31 11:17:00 (sessions) · **22,279** @ 11:16 (distinct users) |
| **Time-weighted average** | **944.6986** (sessions) · 903.9986 (users) |
| Busiest hour, average | 11,277.43 (hour 11:00) |

Evidence: [`evidence/unseen/official-20260802-codex-validation.txt`](evidence/unseen/official-20260802-codex-validation.txt).
Full matrix, the 27 queries verbatim, and a 108-row `system.query_log` extract:
[`evidence/submission/`](evidence/submission/). Every query ran 4× (one warm-up
discarded, three measured) with a caller-supplied `query_id`, query cache off, and
**all 27 returned byte-identical output across all four runs**. Nothing is
hand-computed.

**Latency:** promoted session tiers answer in **2–13 ms**, the user tier's
`uniqExact` merge in **28–40 ms**, and the single un-promoted fallback
(`video_resolution`, no cube level) in **1,117 ms / 753 MiB** — reported rather than
hidden; it is the honest cost of a dimension that arrived *with* the unseen file and
was never pre-aggregated.

> **Where these numbers were produced.** The official 7,000,000-row build lives in a
> **local ClickHouse container**; the hosted Cloud service holds the original
> 905,558-row file and a rehearsal slice. **Correctness is host-independent** — the
> zero-mismatch reconciliation is the proof. **The millisecond latencies are not** —
> they are local-container timings, labelled as such. Seven further limitations are
> named in [`evidence/submission/results-matrix.txt`](evidence/submission/results-matrix.txt) §10.

**Two properties judges should not have to discover:** peak concurrency is **not
summable across dimensions** — the 19 per-platform peaks sum to 24,025 (+3.01%)
against the true 23,324, and their max is 7,163 (−69.29%); both wrong, in opposite
directions — and average concurrency is **time-weighted**, not a mean of per-minute
values.

## Hosted Demo

**<HOSTED_DEMO_URL>** — *(mandatory; must show the concurrency curve rendered in the
dashboard with working dataset filters, per the SonyLIV track guidelines)*

The demo runbook — exactly what to show and in what order — is
[`deck/final/README.md`](deck/final/README.md) § "The demo, slide 08". Set the time
range to **2026-07-31 00:00 → 23:59 UTC** first: the unseen day holds 99.088% of the
data and panels render empty outside it.

## Demo Video

**<VIDEO_URL>** — *(mandatory; 2–3 minutes, recorded; must show the curve, the
filters moving it, and ClickStack live)*

## Architecture

Full document: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · design decisions with
trade-offs: [`docs/adr/`](docs/adr/). In brief:

```
ev_raw  (lossless all-String landing; a malformed row costs a row, not the file)
  │       ORDER BY (video_session_id, event_timestamp)
  ├─▶ session_intervals   ACTIVE ranges per session
  │     · heartbeat gap > 150 s closes a range   (backgrounding: heartbeats STOP)
  │     · explicit pause→resume subtracted        (pause: heartbeats SURVIVE)
  │     · versioned ReplacingMergeTree — re-derivation REPLACES, ranges can shrink
  ├─▶ cc_minute_delta     +1 at open, −1 at close, HOUR-CLIPPED
  │     each hour's running sum is absolute — no query ever scans from t=0
  ├─▶ cc_hour_agg         peak + integral per hour, dimension cube
  │     peak is maxable over time but NOT summable across dimensions
  ├─▶ cc_user_minute      USER concurrency — uniqExact states, not deltas
  │     (uniq's HLL sketch carries 1–2% error; not acceptable for a headline number)
  └─▶ windows + content   rolling / tumbling / range views; content metadata by join
```

The gate that makes the numbers trustworthy is
[`tools/reconcile.sh`](tools/reconcile.sh): it recomputes concurrency **from raw
events only**, using a different implementation of the same spec (window functions
rather than array splitting), so an error in one shows up instead of cancelling out.
It never reads the serving tables — which is exactly the spot-check judges perform.

### Concurrency curve — the queries behind it

The curve is rendered live in ClickStack/HyperDX dashboards (not a static image).
The ClickHouse SQL that computes it is committed:

- Model derivation: [`sql/`](sql/) — intervals → deltas → hour cube → user tier → views
- The benchmark-shaped peak/average queries, verbatim with query IDs:
  [`evidence/submission/`](evidence/submission/) and [`queries/`](queries/)
- Dashboard panel SQL, per tile: [`docs/DASHBOARD_PROVENANCE.md`](docs/DASHBOARD_PROVENANCE.md)

## Dataset filters, and the columns behind them

Full mapping with measured cardinalities, filtered peaks and query IDs:
[`docs/FILTERS.md`](docs/FILTERS.md). Unfiltered baseline: **peak 23,324 @
2026-07-31 11:17**. Filters apply to the concurrency curve and every other view.

| Filter | Column · table | Filtered peak | Moves the curve? |
|---|---|---:|---|
| Platform | `platform` · ev_raw | 7,159 | −69.3% |
| **Country** | `country` · ev_raw | 23,324 | **no — see below** |
| Title | `title` · content_dim | 9,143 | −60.8% |
| Content ID | `content_id` · ev_raw | 9,143 | −60.8% |
| App version | `app_version` · ev_raw | 4,922 | −78.9% |
| Audio language | `audio_language` · ev_raw | 11,801 | −49.4% |
| Subtitle language | `subtitle_language` · ev_raw | 18,257 | −21.7% |
| Player version | `player_version` · ev_raw | 18,958 | −18.7% |
| Video resolution | `extra['video_resolution']` · ev_raw | 5,289 | −77.3% |
| Show name | `extra['show_name']` · content_dim | 9,179 | −60.6% |
| Video type | `video_type` · content_dim | 10,778 | −53.8% |
| Category | `category` · content_dim | 9,317 | −60.1% |

**`country` is a dead filter, and we say so rather than remove it.** It is the
constant `'india'` in all 7,000,000 unseen rows *and* the graded file, so
`WHERE country='india'` returns the identity curve. 11 of 12 filters genuinely alter
the curve; hiding the control would not change the fact, only who discovers it.

Beyond magnitude, the curve's **shape** changes too: the peak minute itself moves
for 7 of the 12, and support collapses from 4,334 minutes to as few as 367. Two
filters (`video_resolution`, `show_name`) are `ALIAS` columns over the `extra` map —
the mechanism that lets a *new* column on an unseen day become filterable the same
day, with no migration.

## How we built it

**Stack:** ClickHouse Cloud (primary datastore and analytical engine) ·
ClickStack/HyperDX (dashboards + observability, the OSS integration) · Go CLI
(`cmd/sonyliv`) for load/build/observe · OpenTelemetry (pipeline self-telemetry) ·
Docker Compose · pure-SQL model in [`sql/`](sql/).

Implementation notes judges may care about:

- **Tuned constants live in one declaration** ([`policy/model.policy`](policy/model.policy))
  read by every consumer, so any answer can name the policy it was produced under.
- **Late arrivals and still-open sessions** are absorbed by an incremental publisher
  (ADR [0013](docs/adr/0013-continuous-publication-by-incremental-finalizer.md)) — an
  MV records touched sessions; only those are re-derived and diffed into the serving
  tiers. Proven equal to a from-scratch rebuild ([`evidence/publish.txt`](evidence/publish.txt)).
- **Scale, measured not claimed:** at 1×/10×/100×, serving latency stays flat
  (2.1–17.2 ms — hour-clipping makes reads window-bound); the interval build is what
  strains, and at 100× needed spill plus two threads
  ([`evidence/scale.txt`](evidence/scale.txt)).
- **Vendored official ClickHouse agent skills** (31 best-practice rules) are cited in
  schema/query decisions and overturned one of our own choices
  (ADR [0002](docs/adr/0002-order-by-time-bucket-then-platform.md)).

### ClickStack integration

Wiring committed, per the organiser's evidence requirements:

| Evidence | Where |
|---|---|
| Deployment config | [`docker-compose.yml`](docker-compose.yml) |
| Redacted env template | [`.env.example`](.env.example) — no credentials committed anywhere (verified: 0 commits, 0 tracked files) |
| OTel integration code | [`internal/otelemit/`](internal/otelemit/), [`cmd/sonyliv/observe.go`](cmd/sonyliv/observe.go) |
| Collector / ingestion detail | [`docs/CLICKSTACK_SUBMISSION.md`](docs/CLICKSTACK_SUBMISSION.md), [`docs/OBSERVABILITY.md`](docs/OBSERVABILITY.md) |
| What every dashboard panel shows | [`docs/CLICKSTACK_DASHBOARDS.md`](docs/CLICKSTACK_DASHBOARDS.md) — 6 dashboards, 41 tiles |
| Per-panel SQL + lineage to raw | [`docs/DASHBOARD_PROVENANCE.md`](docs/DASHBOARD_PROVENANCE.md) |

**The destination is split, and we state it rather than blur it.** Dashboards
**read** the graded ClickHouse Cloud service, database `sonyliv`. OTLP telemetry
about our own pipeline **writes** to the ClickStack container's bundled ClickHouse
(`otel_metrics_gauge`, `otel_logs`, `otel_traces`), because the Cloud service
exposes no OTLP endpoint (verified — it has no `otel_*` tables). ClickStack's role
in the pipeline: it renders the concurrency product dashboards *and* observes the
pipeline itself — ingestion lag, watermark age, build timing, reconcile-gate status
([`docs/OBSERVABILITY.md`](docs/OBSERVABILITY.md)).

<!-- [HUMAN] Embed real ClickStack dashboard screenshots here, e.g.:
![Concurrency curve, unseen day](screenshots/clickstack-curve.png)
![Filters applied](screenshots/clickstack-filters.png)
![Pipeline health](screenshots/clickstack-pipeline.png)
-->

## How to run it

```bash
cp .env.example .env          # fill in CH_PASSWORD_LOCAL and AGENT_PASSWORD
docker compose up -d          # local ClickHouse (+ ClickStack via `make stack-up`)
tools/fetch_data.sh           # organiser CSVs, sha256-verified — data is NOT in the repo
tools/load.sh                 # exact-count-checked load (re-running cannot double a day)
make model                    # intervals → deltas → hour cube → user tier → views
tools/reconcile.sh            # THE GATE — recomputes from raw, exits 1 on any mismatch
```

Go toolchain: `direnv allow`, then `make ci` (pinned by devbox —
[`docs/GO.md`](docs/GO.md)). ClickStack: `make stack-up && make clickstack`, then set
the time range to the dataset's dates (it is not "now") —
[`docs/CLICKSTACK.md`](docs/CLICKSTACK.md). Offline demo without credentials:
`demo/run.sh --offline`. Unseen-day runbook:
[`docs/RUNBOOK_UNSEEN.md`](docs/RUNBOOK_UNSEEN.md).

## Known limitations, stated rather than hidden

- **Explicit `AppBackgrounded` is not a state gate.** We detect backgrounding by
  heartbeat gap (150 s), not the explicit markers — those are documented as not
  guaranteed and are sharply asymmetric in the official file (46.8% of backgrounds
  never followed by a foreground). Measured end to end: a hard state gate moves the
  peak by −17 (−0.073%); the same measurement surfaced a larger effect (60 s tail
  grace past a terminal background, −202 at peak) that a state gate does *not*
  remove. Total exposure bounded at **0.72% of counted watch time, 0.91% at peak**.
  We ship the reconciled gap-only reading and disclose the bound
  ([ADR 0035](docs/adr/0035-explicit-appbackgrounded-is-not-a-state-gate.md),
  [`evidence/backgrounded/`](evidence/backgrounded/)).
- **The peak *minute* is less stable than the peak *value*** — 11:17 leads 11:16 by
  only 6 viewers, and every alternative reading reverses the ordering.
- **Point activity** — 182 single-event runs earn nothing; keeping them moves the
  sample peak 2,917 → 2,927. Measured both ways
  ([ADR 0031](docs/adr/0031-point-activity-user-attribution-and-the-densify-recipe.md)).
- **Session identity** — 159 unseen session IDs carry more than one start epoch, 303
  more than one user; grouping by `video_session_id` alone can merge incarnations.
- Constants were fitted on the sample data; a different corpus could justify
  different values.

**Secret-scan note for whoever publishes this:** `.env` was never committed and the
Cloud password appears nowhere in tracked files or history, but the Cloud
**hostname** appears in `evidence/load-guard.txt` and in history. A hostname alone
grants no access — decide deliberately whether to scrub or accept, and rotate
credentials after the event regardless.

## Licence

MIT — see [LICENSE](LICENSE).
