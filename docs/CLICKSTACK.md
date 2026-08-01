# CLICKSTACK — the OSS integration, and where the concurrency chart comes from

> **Summary:** ClickStack does **two** jobs — it observes our pipeline over OTLP (ingestion lag,
> query latency) and it *is* the concurrency visualization the statement asks for, so we ship no
> custom frontend. **Two ways to run it. We use Option B:** HyperDX built into ClickHouse Cloud
> (confirm via the `hyperdx-alert-internal` user) reads `sonyliv` directly — no connection string, no
> IP allowlist. It is **fully scriptable** — `tools/clickstack-cloud.sh` provisions sources, the
> dashboard and saved searches over the Cloud control-plane API. The one value that API cannot yield
> on an empty service is the `connection` id; get it once from the clickstack MCP and put it in
> `.env` as `CLICKSTACK_CONNECTION_ID`. **Option A** is the local all-in-one
> (`make stack-up && make clickstack`). Both chart `sql/20_views.sql`, because no chart tool can read
> an `AggregateFunction` column. Data ends **2026-07-26**: the default 15-minute window renders empty.

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

## Option B — HyperDX built into ClickHouse Cloud (what we actually use)

ClickHouse Cloud ships HyperDX inside the service. Confirm it by looking for the internal user it
provisions:

```bash
tools/ch -c "SELECT name FROM system.users WHERE name LIKE 'hyperdx%'"   # -> hyperdx-alert-internal
```

This is the simpler path and needs **no credentials, no connection, and no IP allowlist change** —
HyperDX is already inside the service, so it reads `sonyliv` as `default` with nothing to configure.
The local `cs` container and `tools/clickstack-sources.sh` are only for Option A.

**It IS scriptable** — via the Cloud control-plane API, not the console session:
`/v1/organizations/{org}/services/{svc}/clickstack/{sources,dashboards,alerts,saved-searches,...}`,
HTTP basic with a Cloud API key (`CH_API_KEY_ID` / `CH_API_KEY_SECRET` in `.env`). Run
`tools/clickstack-cloud.sh`, which provisions sources, the demo dashboard and saved searches.

**The connection id, once.** A source needs a `connection` id and the REST API returns connections
only *nested inside sources* — with no `/clickstack/connections` endpoint (404s on GET and POST).
On a fresh service with zero sources there is therefore nothing to read it from. Resolve it once and
put it in `.env` as `CLICKSTACK_CONNECTION_ID`; after that the script is fully autonomous.

The cleanest way to get it is the **clickstack MCP**, whose `clickstack_list_sources` returns a
top-level `connections` array even when `sources` is empty:

```
claude mcp add clickstack --transport http https://mcp.clickhouse.cloud/clickstack \
  --header "x-service-id: <serviceId>"
```

The MCP can also create sources, dashboards and saved searches directly (`clickstack_save_source`,
`clickstack_save_dashboard`, `clickstack_save_saved_search`) and query them
(`clickstack_timeseries`, `clickstack_sql`) — which is how the numbers below were verified.

If you would rather do the first source by hand:

**ClickHouse Cloud console → HyperDX → Sources → New source**

| Field | Value |
|---|---|
| Name | `Concurrency total (minute)` |
| Database | `sonyliv` |
| Table | `v_concurrency_minute_total` |
| Timestamp column | `minute` (`DateTime`) |
| Value column to chart | `concurrent` (`UInt64`) |

Repeat with `v_concurrency_minute_stateless` for the per-platform/country/content breakdown; it has
the same `minute` timestamp column plus the three dimensions.

Then set the time range to **2026-07-14 → 2026-07-26** before concluding anything is broken.

## What the two scripts do

| Script | Job |
|---|---|
| `tools/clickstack-bootstrap.sh` | registers the team and prints `CLICKSTACK_INGESTION_KEY`. OTLP 4317/4318 do **not** bind until a team exists |
| `tools/clickstack-sources.sh` | self-hosted: registers a ClickHouse connection + sources. Idempotent |
| `tools/clickstack-cloud.sh` | hosted: sources + dashboard + saved searches over the Cloud API. Idempotent |

## The sources

Both come from `sql/20_views.sql` and are registered with `timestampValueExpression = minute`, which
is what makes `minute` the time axis.

| Source | View | Model | Grain |
|---|---|---|---|
| `Concurrency ACCURATE (minute)` | `v_concurrency_minute_intervals` | gap + pause | per minute — **the headline** |
| `Concurrency ACCURATE by dimension` | `v_concurrency_minute_intervals_dim` | gap + pause | per (minute, platform, country, content_id) |
| `Concurrency total (minute)` | `v_concurrency_minute_total` | stateless | per minute — the baseline |
| `Concurrency (minute)` | `v_concurrency_minute_stateless` | stateless | per (minute, platform, country, content_id) |

**Do not SUM `concurrent` across dimensions.** A session watching two content_ids appears under both;
the total view re-merges the underlying states instead, which deduplicates. This is the same trap
described in [ARCHITECTURE.md](ARCHITECTURE.md) — peak is not summable.

Both models are charted side by side — the comparison is an explicit deliverable, so they are never
merged behind one name. At the peak minute the accurate model reads **2,887** against the stateless
**2,894**: the gap is backgrounded and paused time the accurate model excludes.

The `_intervals` views expand each active interval across the minutes it covers. That is the
O(sessions × minutes) explosion the statement warns about and is **not** the serving path —
`cc_minute_delta` (TODOS H3) is. At 30,769 intervals it answers in ~60 ms, so it charts the real
model today; swap the source to the delta table when H3 lands, the columns match on purpose.

## Verified

Through HyperDX itself, not by querying ClickHouse directly.

**Hosted**, via the MCP's `clickstack_timeseries` against the provisioned source — the live-event
curve renders end to end:

```
2026-07-26 10:00 →  61      ramp
             10:30 → 1048
             10:55 → 2894   ← peak, matches the ClickHouse-side figure exactly
             11:25 →  889
             11:30 →    7   decay
28 ms · 83,648 rows read
```

**Self-hosted**, through its proxy:

```
POST /clickhouse-proxy?query=... with header x-hyperdx-connection-id
-> 200 in 0.52s
   peak 2894 concurrent @ 2026-07-26 10:56
   elapsed 0.050s · rows_read 91,292 · bytes_read 18.6 MB
```

## The dashboard

`tools/clickstack-cloud.sh` creates **SonyLIV concurrency**: five line tiles — accurate headline,
stateless baseline, then accurate split by platform / content / country — plus three dashboard
**filters** (Platform, Country, Content) wired via `appliesToSourceIds` so one control drives every
dimensional tile. The two total-only sources are deliberately excluded from `appliesToSourceIds`:
they have no dimension columns, so naming them would make the filter error rather than no-op.

A re-run **PUTs** the dashboard rather than skipping it, so the definition in the script is the
source of truth and a hand-edit in the UI cannot silently outlive it. It runs the payload through `POST /clickstack/dashboards/validate` *before*
creating, so a malformed tile fails with a JSON path rather than as a blank panel mid-demo.

Schema notes, from the spec rather than guesswork: `ClickStackCreateDashboardRequest` requires
`{name, tiles}`; each `ClickStackTileInput` requires `{name, x, y, w, h}`; a line tile's
`ClickStackLineBuilderChartConfig` requires `{displayType, sourceId, select}`. There is also a
raw-SQL variant (`ClickStackLineRawSqlChartConfig`) needing `{configType:"sql", connectionId,
sqlTemplate, displayType}` if a tile ever outgrows the builder.

## Gotchas

- **Empty chart?** Time range. The data is July 2026, not now. This costs everyone ten minutes once.
- The API serves **no route at `/`** and answers 404 there. Readiness is `/health` — probing `/` with
  `curl -f` waits out the full timeout against a server that was up the whole time.
- Registration lives at the **root** (`/register/password`), not under `/api`.
- The `cs` container needs a TTY or it boots fully and then exits 129 — `tty: true` in compose.
- ClickStack bundles its **own** ClickHouse 26.5.6 for otel data. That is not our database; do not
  build the project on it. Our connection points at Cloud explicitly.
- The Cloud API has **no connections endpoint** — `/clickstack/connections` 404s on GET and POST and
  no `ClickStackConnection` schema exists. Opening HyperDX once in the console is unavoidable.
- `-u "$ID:$SECRET"` must be **quoted at the call site**. zsh does not word-split an unquoted
  variable holding `-u id:secret`, so curl gets one argument and the API returns
  `401 "Key is not found"` — which reads exactly like a bad key and sends you debugging the wrong thing.
- **Create and update validate against different schemas.** `filters[]` on POST/validate is
  `ClickStackFilterInput`, which *forbids* `id`; on PUT it is `ClickStackFilter`, which *requires*
  it. The script emits both shapes from one definition.
- `/clickhouse-proxy` requires **POST** with the query in the URL. GET returns 405; a missing
  `x-hyperdx-connection-id` header returns a Zod validation error.
