# Foreground-only concurrency at streaming scale

> Click-a-thon India 2026 · **SonyLIV track** · ClickHouse Cloud is the primary datastore and
> analytical engine; ClickStack is the dashboard and observability integration. **Judges: start
> here, then [SUBMISSION.md](SUBMISSION.md)** — every claim there is mapped to evidence. Submission
> status on 2026-08-02: the portal closes automatically at **12:00 PM IST**; wiring exists, but
> hosted-demo/video links, live ClickStack walkthrough and the self-contained team package are still
> missing and are not claimed complete.

**The question:** how many people are *actually watching* at each minute? An open app is not a
watching viewer. Sessions sit backgrounded, paused, or silent with no heartbeat, and counting that
time overstates the audience. This system reconstructs the truly-active ranges inside each session
from start/end events plus player telemetry, and answers minute-grain, filtered peak/average
concurrency from a pre-aggregated serving layer — never by rescanning session history.

## The result, in four numbers

All re-verified live against the graded ClickHouse Cloud service on **2026-08-01** (read-only;
regeneration commands in [SUBMISSION.md](SUBMISSION.md)):

| | naive session-span | **this model** | |
|---|---|---|---|
| Peak concurrency (2026-07-26 10:56 UTC) | 3,708 | **2,917** | 21.3% overcount eliminated |
| Total counted watch time (12 days) | 2,976.9 h | **1,978.1 h** | **33.6% of apparent watch time was backgrounded or paused** |
| Peak concurrent *users* (vs sessions) | — | **2,844** | 72 users hold >1 concurrent session at the peak |
| The correctness gate | — | **17,028/17,028 minutes match, 0 mismatches** | truth recomputed from raw events by an independent implementation |

The 33.6% is the whole point of the problem: a dashboard built on session spans would report an
audience one-third larger than the one actually watching.

## See it work (10 minutes)

Three commands, in increasing order of proof:

```bash
make ci               # Go toolchain: vet, lint, race-tested unit suite, build — green
demo/run.sh --offline # the full 5-minute demo from committed evidence — no credentials needed
tools/reconcile.sh    # THE GATE: recompute truth from raw events, compare every minute, exit 1 on any mismatch
```

`demo/run.sh` (without `--offline`) runs the same demo live against ClickHouse Cloud — rehearsed
end-to-end on 2026-08-01, 11 s of machine time, every beat with a committed fallback
(`evidence/demo/rehearsal.txt`). The gate needs a loaded database (setup below); `TARGET=cloud
tools/reconcile.sh` runs it read-only against the graded service.

## Official submission status

- **Hosted demo:** not yet published.
- **Required 2–3 minute video:** not yet recorded; the existing five-minute script is an engineering
  walkthrough and is not the final submission video.
- **ClickStack wiring:** committed in `docker-compose.yml`, `.env.example`, `internal/otelemit/`,
  `cmd/sonyliv/observe.go`, and `tools/clickstack-*.sh`.
- **ClickStack data path:** the local all-in-one service receives OTLP into its bundled ClickHouse
  tables `otel_metrics_gauge`, `otel_logs`, and `otel_traces`. Hosted HyperDX has no OTLP path; it
  reads the graded ClickHouse Cloud `sonyliv` serving views and `system.query_log` directly.
- **Still required for the official folder:** actual ClickStack dashboard/search screenshots in the
  team README and a live walkthrough in both hosted demo and video. Generated previews and query
  transcripts are supplemental only; the official contract says screenshots alone are insufficient.

## The model, in one picture

```
ev_raw   905,558 events · 10,866 sessions · 2026-07-14 15:43 → 2026-07-26 11:30 UTC
  │        ORDER BY (video_session_id, event_timestamp) — one session's events are adjacent
  │
  ├─▶ session_intervals   30,323 rows      ACTIVE ranges per session
  │     · a heartbeat gap > 150 s closes a range   (backgrounding: heartbeats STOP)
  │     · explicit pause→resume windows subtracted (pause: heartbeats SURVIVE — see below)
  │     · versioned ReplacingMergeTree: a re-derivation REPLACES, so corrections can shrink a range
  │
  ├─▶ cc_minute_delta     28,073 rows      +1 at open, −1 at close, HOUR-CLIPPED, 7 raw dimensions
  │     concurrency(M) = running sum of deltas within M's hour — each hour absolute,
  │     so no query ever scans from t=0. O(intervals) rows, NOT O(sessions × minutes).
  │
  ├─▶ cc_hour_agg         26,254 rows      peak + integral per hour, 8-level dimension cube
  │     peak is maxable over time but NOT summable across dimensions — stored per level
  │
  ├─▶ cc_user_minute                       USER concurrency — uniqExact states, not deltas
  │     (one user can hold several sessions; summing session deltas would double-count them)
  │
  ├─▶ windows + content   rolling / tumbling / range views; content metadata via direct join
  │
  └─▶ cc_minute_stateless 91,292 rows      session-INDEPENDENT baseline for comparison
        (uniqExact of sessions seen active; peak 2,894 vs the session-aware 2,917)
```

### The one insight that decides correctness

Backgrounding and pausing look identical on a dashboard but are opposite in the data
([ADR 0007](docs/adr/0007-gate-answers-pause-needs-explicit-handling.md), measured):

| State | Heartbeat rate | Detectable by gaps? |
|---|---|---|
| Actively watching | 4.72 /min | — |
| Backgrounded | 0.047 /min (100× drop) | yes — the gap closes the range |
| **Paused** | **0.756 /min — heartbeats keep flowing** | **no** — must be excluded explicitly |

A gap-only model silently counts paused time as watching. Ours subtracts explicit pause→resume
windows *and* closes on gaps; the two mechanisms are independent and both necessary.

## Two known defects in our own model

**Q35** — a viewer who generated exactly one event counts as watching nothing. 182 runs; counting
them moves the peak **2,917 → 2,927**. We answer "nothing" by accident, not by choice, and our own
correctness gate cannot see it because it shares the filter. **2,917 is our submitted number**;
this is the one internal question that would change it.

**Q34** — user concurrency exceeds session concurrency in 82 cells, worst excess +1, no total
affected.

Both are ours, not mentor questions. Full list in [`SUBMISSION.md`](SUBMISSION.md); eleven measured
questions for the organisers in [`doubts/`](doubts/).

## Performance and updates, in one paragraph each

**Queries.** 13 benchmark-shaped queries (peak + average at minute/hour/day grain, with dimension
filters) run at **7–45 ms server-side median**, reading **≤ 814 KiB** each — from the serving
tiers, never raw history. Every run's `query_id` is committed so the numbers are auditable in
`system.query_log`: [`evidence/bench.txt`](evidence/bench.txt), raw pack
[`evidence/benchmark/`](evidence/benchmark/).

**Updates.** Late arrivals and still-open sessions are absorbed by an incremental publisher
([ADR 0013](docs/adr/0013-continuous-publication-by-incremental-finalizer.md) +
[ADR 0016](docs/adr/0016-publisher-owns-the-user-and-hour-tiers.md)): an MV records which sessions
each insert touched; the publisher re-derives only those and corrects the serving tiers by
appending diffs — no truncate, no rebuild. Proven equal to a from-scratch rebuild across all four
tiers, including a 46-minute straggler and 200 forced republications
([`evidence/publish.txt`](evidence/publish.txt)). Honesty note: this is proven in a scratch
database; the graded database has the layer installed but its numbers were produced by batch
rebuilds — details in [SUBMISSION.md](SUBMISSION.md).

## What we know is still wrong

We keep a live list of open problems rather than hiding them — the model is only as good as its
assumptions, and some remain semantic policy choices that judge raw-event spot-checks may expose:

- **`resume` semantics are worth 9.7% of the headline** — the largest measured fork
  ([doubts/02](doubts/02-resume-semantics.md)). Six evidence-backed questions live in
  [doubts/](doubts/), each with a decision table per possible answer.
- **The 13-query matrix is our reconstruction** — the organiser specifies required peak/average
  minute/hour/day results with filters, not fixed SQL.
- **The graded database is batch-rebuilt**, not publisher-maintained (above).
- The full list, with evidence: [SUBMISSION.md § known limitations](SUBMISSION.md) and
  [docs/MENTOR_QUESTIONS.md](docs/MENTOR_QUESTIONS.md).

## Run it yourself

```bash
cp .env.example .env          # fill in CH_PASSWORD_LOCAL and AGENT_PASSWORD
docker compose up -d
tools/fetch_data.sh           # 223 MB of organiser CSVs, sha256-verified — data is NOT in the repo
tools/load.sh                 # exact-count-checked load (re-running cannot double the day)
make model                    # intervals → deltas → hour cube → user tier → views
tools/reconcile.sh            # the gate — exits 1 on any mismatch
```

Go toolchain (`make ci`) is pinned by devbox and entered by direnv: `direnv allow`, detail in
[docs/GO.md](docs/GO.md). The concurrency chart is ClickStack/HyperDX, which doubles as the OSS
integration — `make stack-up && make clickstack`, then set the time range to **2026-07-14 →
2026-07-26** (the dataset is not "now"); detail in [docs/CLICKSTACK.md](docs/CLICKSTACK.md).

## Where things are

| | |
|---|---|
| **The submission, mapped to judging criteria** | [SUBMISSION.md](SUBMISSION.md) |
| Plain-English explainer of the whole problem | [docs/EXPLAINER.md](docs/EXPLAINER.md) |
| The model and why | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Honest project state, verified vs assumed | [WALKTHROUGH.md](WALKTHROUGH.md) · [docs/VERIFIED.md](docs/VERIFIED.md) |
| Design decisions with trade-offs (16 ADRs) | [docs/adr/](docs/adr/) |
| Every number's provenance | [evidence/](evidence/) — regenerated by scripts, never hand-computed |
| Data shape and its traps | [docs/DATA_DICTIONARY.md](docs/DATA_DICTIONARY.md) |
| Behaviour at 100× | [evidence/scale.txt](evidence/scale.txt) |
| The unseen-day runbook | [docs/RUNBOOK_UNSEEN.md](docs/RUNBOOK_UNSEEN.md) |
| Scripts | [tools/README.md](tools/README.md) · agent router: [AGENTS.md](AGENTS.md) |

## Licence

MIT — see [LICENSE](LICENSE).
