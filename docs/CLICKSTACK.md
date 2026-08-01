# CLICKSTACK — the OSS integration, and where the concurrency chart comes from

> **Summary:** ClickStack (HyperDX all-in-one) runs locally from `docker-compose.yml` under the `oss`
> profile and does **two** jobs: it observes our own pipeline over OTLP (ingestion lag, query
> latency), and it *is* the concurrency visualization the problem statement asks for — so we ship no
> custom frontend. `make stack-up && make clickstack` gets both. Charts read the graded **Cloud**
> service through a HyperDX connection, over the views in `sql/20_views.sql`, because a chart tool
> cannot read an `AggregateFunction` column. The dataset ends **2026-07-26**: HyperDX's default
> "last 15 minutes" window renders an empty chart and looks broken. Set the range.

## Why ClickStack is the chart, not just the telemetry

The statement puts polished frontends out of scope — "a minimal visualization of concurrency over
time is enough to demo" ([PROBLEM.md](PROBLEM.md), Out of scope). ClickStack is separately the OSS
integration we are asked to use. Pointing HyperDX at our own serving layer satisfies both with one
component and zero UI code, and every chart is backed by a real query against the graded service
rather than a screenshot of a number someone typed.

## Bring it up

```bash
make stack-up      # ClickHouse + ClickStack; waits for /health
make clickstack    # register the team + OTLP key, then our concurrency sources
open http://localhost:8080
```

Then in HyperDX: pick source **Concurrency total (minute)**, set the time range to
**2026-07-14 → 2026-07-26**, and chart `concurrent` over `minute`.

## What the two scripts do

| Script | Job |
|---|---|
| `tools/clickstack-bootstrap.sh` | registers the team and prints `CLICKSTACK_INGESTION_KEY`. OTLP 4317/4318 do **not** bind until a team exists |
| `tools/clickstack-sources.sh` | registers a ClickHouse connection to Cloud + sources over the concurrency views. Idempotent |

## The sources

Both come from `sql/20_views.sql` and are registered with `timestampValueExpression = minute`, which
is what makes `minute` the time axis.

| Source | View | Grain |
|---|---|---|
| `Concurrency total (minute)` | `v_concurrency_minute_total` | one row per minute — the headline curve |
| `Concurrency (minute)` | `v_concurrency_minute_stateless` | per (minute, platform, country, content_id) |

**Do not SUM `concurrent` across dimensions.** A session watching two content_ids appears under both;
the total view re-merges the underlying states instead, which deduplicates. This is the same trap
described in [ARCHITECTURE.md](ARCHITECTURE.md) — peak is not summable.

These read the **stateless** model. When the gap-based model lands (TODOS H3), it gets its own view
and its own source; the two are deliberately never merged behind one name, because comparing them is
an explicit deliverable.

## Verified

End-to-end through HyperDX's own proxy, not by querying ClickHouse directly:

```
POST /clickhouse-proxy?query=... with header x-hyperdx-connection-id
-> 200 in 0.52s
   peak 2894 concurrent @ 2026-07-26 10:56
   elapsed 0.050s · rows_read 91,292 · bytes_read 18.6 MB
```

## Gotchas

- **Empty chart?** Time range. The data is July 2026, not now. This costs everyone ten minutes once.
- The API serves **no route at `/`** and answers 404 there. Readiness is `/health` — probing `/` with
  `curl -f` waits out the full timeout against a server that was up the whole time.
- Registration lives at the **root** (`/register/password`), not under `/api`.
- The `cs` container needs a TTY or it boots fully and then exits 129 — `tty: true` in compose.
- ClickStack bundles its **own** ClickHouse 26.5.6 for otel data. That is not our database; do not
  build the project on it. Our connection points at Cloud explicitly.
- `/clickhouse-proxy` requires **POST** with the query in the URL. GET returns 405; a missing
  `x-hyperdx-connection-id` header returns a Zod validation error.
