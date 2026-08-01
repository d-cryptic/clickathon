# CLICKSTACK_DASHBOARDS — what every panel shows, and how to read it

> **Summary:** Panel-by-panel reference for the six HyperDX dashboards on the hosted ClickStack
> (Cloud), captured **live from the running service** on 2026-08-01, not from the provisioning scripts.
> **6 dashboards · 41 tiles · 24 sources · 1 connection.** Read this with
> [CLICKSTACK.md](CLICKSTACK.md), which covers *bringing the stack up*; this file covers *what is on
> the screen and what it means*. **The single most common failure is the time range** — the data ends
> 2026-07-26, so HyperDX's default 15-minute window renders every panel empty. Set
> **2026-07-14 → 2026-07-26** before concluding anything is broken.

**Captured:** 2026-08-01 · hosted HyperDX in ClickHouse Cloud · connection `ClickathonProject` ·
database `sonyliv` · all tiles read our own serving views, never raw events.

---

## 0 · The shape of it

```
                          ClickHouse Cloud · sonyliv
                                     │
        ┌────────────────────────────┼────────────────────────────┐
        │ serving views              │ system.query_log           │
        ▼                            ▼                            ▼
   24 HyperDX sources ────────────────────────────────────────────┘
        │
        ├─▶ 1. SonyLIV concurrency          10 tiles   THE HEADLINE
        ├─▶ 2. SonyLIV drilldown            8 tiles + 8 filters
        ├─▶ 3. SonyLIV content              7 tiles
        ├─▶ 4. SonyLIV time-window trend    4 tiles
        ├─▶ 5. SonyLIV pipeline health      7 tiles    ← observes US
        └─▶ 6. SonyLIV query cost           5 tiles    ← observes US
                                            ────────
                                            41 tiles
```

Dashboards 1–4 chart **the product**. Dashboards 5–6 chart **our own pipeline** — that is the
both-directions claim: ClickStack is not only where our data is drawn, it is where our *pipeline's*
health is observed. Delete it and the freshness and cost panels have nowhere to come from.

---

## 1 · `SonyLIV concurrency` — the headline

The dashboard to open first, and the one the demo leads with.

```
 ┌──────────────┬──────────────┬──────────────┬──────────────┐
 │ Peak         │ Peak         │ Peak         │ Peak         │  ← 4 number tiles
 │ ACCURATE     │ stateless    │ NAIVE        │ distinct     │
 │ (green)      │ baseline     │ session-span │ users        │
 └──────────────┴──────────────┴──────────────┴──────────────┘
 ┌────────────────────────────────────────────────────────────┐
 │ Concurrency — ACCURATE, gap + pause excluded               │  ← the money chart
 │ (peak 2,917 @ 2026-07-26 10:56)                            │
 └────────────────────────────────────────────────────────────┘
 ┌───────────────┬───────────────┬────────────────────────────┐
 │ ACCURATE      │ STATELESS     │ NAIVE session-span         │  ← the comparison,
 │ session-aware │ session-indep │ "the over-count"           │    side by side
 └───────────────┴───────────────┴────────────────────────────┘
 ┌──────────────────────────┬─────────────────────────────────┐
 │ Distinct users           │ Rolling 15-min peak             │
 │ (uniqExact, NOT deltas)  │                                 │
 └──────────────────────────┴─────────────────────────────────┘
```

| Tile | Reads | What it means |
|---|---|---|
| **Peak — ACCURATE** | `Concurrency ACCURATE (minute)` → `max(concurrent)` | The graded number. Foreground-only: gaps exclude backgrounding, explicit pause/resume excludes pausing. **2,917** |
| **Peak — stateless** | `Concurrency total (minute)` | The session-**in**dependent model, straight from event state. **2,894** |
| **Peak — NAIVE** | `Concurrency NAIVE session-span` | What you get counting session start→end overlap. **3,708** |
| **Peak — distinct users** | `User concurrency (minute)` → `max(concurrent_users)` | Distinct *people*, not sessions. **2,844.** Note the column is `concurrent_users`, **not** `concurrent` |
| **The ACCURATE curve** | same source, `max(concurrent)` per bucket | The live-sport shape: flat, then a near-vertical climb into 10:00 on 26 July |
| **Three curves side by side** | three sources | **This trio is the deliverable.** The spec demands both models *and* a comparison; naive is the third for contrast |
| **Distinct users** | `concurrent_users` | Users are **not summable** across dimensions — a `uniqExact` set union, never a delta sum |
| **Rolling 15-min peak** | `Rolling windows (minute)` → `peak_15m` | Smooths the spike; see dashboard 4 |

**How to read the trio.** The gap between naive and accurate *is* the answer:

```
  3,708  naive        ████████████████████████████████████  session start→end overlap
  2,917  accurate     ████████████████████████████          foreground-only
  2,894  stateless    ███████████████████████████▉          session-independent
                      └────── 791 viewers ──────┘  = 21.3% over-count eliminated
```

Accurate sits *slightly below* stateless because the stateless model still counts paused viewers —
heartbeats survive a pause. That small gap is the pause exclusion, made visible.

---

## 2 · `SonyLIV drilldown — sessions & users` — the filter story

Eight tiles, all from one source (`Session minutes (drilldown)`), plus **8 dashboard filters** wired
to it: platform, country, title, content_id, app_version, audio_language, subtitle_language,
player_version. One control drives every tile.

```
 ┌────────────────────────────────────────────────────────────┐
 │ Sessions vs distinct users (= concurrency at 1-min zoom)   │
 └────────────────────────────────────────────────────────────┘
 ┌─────────────────────────┬──────────────────────────────────┐
 │ by platform             │ by country                       │
 ├─────────────────────────┼──────────────────────────────────┤
 │ by app_version          │ by audio_language                │
 ├─────────────────────────┼──────────────────────────────────┤
 │ by subtitle_language    │ by player_version                │
 └─────────────────────────┴──────────────────────────────────┘
 ┌────────────────────────────────────────────────────────────┐
 │ by title (top 20)                                          │
 └────────────────────────────────────────────────────────────┘

 FILTERS:  platform · country · title · content_id · app_version
           audio_language · subtitle_language · player_version
```

Tiles use `count_distinct(video_session_id)` and `count_distinct(user_id)` **per bucket**. At
1-minute zoom that equals concurrency; zoom out and it becomes "distinct sessions active anywhere in
the bucket", which is a **larger** number. Say which you mean before quoting it.

⚠ **`audio_language` will show Hindi four times** — `hin`, `HIN`, `hin-hindi`, `hin-Hindi`. That is
real, un-normalised source data, not a bug in the panel. Normalisation exists
([ADR 0011](adr/0011-normalise-filter-dimensions-at-query-time.md)) but is **not deployed to Cloud**.

---

## 3 · `SonyLIV content` — demand by title

```
 ┌──────────────────────────┬─────────────────────────────────┐
 │ Top titles by peak       │ NOW — by title (last minute)    │  tables
 ├──────────────────────────┼─────────────────────────────────┤
 │ by video_type            │ by category (top 20)            │  lines
 ├──────────────────────────┼─────────────────────────────────┤
 │ Top titles over time (top 20)                              │  line, full width
 ├──────────────────────────┼─────────────────────────────────┤
 │ NOW — by video_type      │ NOW — by category               │  tables
 └──────────────────────────┴─────────────────────────────────┘
```

The **NOW** tiles use `argMax(concurrent, minute)` — the value at the newest minute the delta layer
has produced. They answer "what is being watched *right now*".

Two caveats worth stating before a judge finds them:

- **`title` is not a key.** 2,773 titles are shared by 2–4 different `content_id`s, and 1,418 of those
  collisions span different categories. A title row therefore merges distinct assets. The arithmetic
  is right; the label is ambiguous.
- **`video_type` has three values, not two** — `vod`, `live`, and the **empty string** (1,089 catalog
  rows, 2.85% of events). Expect a blank third series.

---

## 4 · `SonyLIV time-window trend` — the required aggregation

```
 ┌────────────────────────────────────────────────────────────┐
 │ Rolling peaks — instantaneous vs 5 / 15 / 60-min windows   │
 └────────────────────────────────────────────────────────────┘
 ┌────────────────────────────────────────────────────────────┐
 │ Rolling time-weighted averages — 5 / 15 / 60-min           │
 └────────────────────────────────────────────────────────────┘
 ┌──────────────────────────┬─────────────────────────────────┐
 │ Tumbling 15-min          │ Tumbling 1-hour                 │
 │ (raw SQL tile)           │ (straight from cc_hour_agg)     │
 └──────────────────────────┴─────────────────────────────────┘
```

This dashboard answers the organiser's third core aggregation — *"time-window trend: window duration,
watermarking, refresh latency"*.

- **Rolling** panels use `RANGE` window frames, not `ROWS`. The delta layer stores a row only where
  concurrency *changes*, so "5 rows back" is not "5 minutes back". `RANGE` is defined on the values of
  the ordering column, so the frame is a real time window.
- **Tumbling 15-min** is the only **raw-SQL tile** on any dashboard. It calls a parameterised view:
  `SELECT window_start, peak, avg FROM sonyliv.v_cc_tumbling_total(win=15)`. The width must divide 60,
  or a bucket would straddle an hour boundary and its max would not be a real peak.
- **Tumbling 1-hour** does **no computation at all** — the hour *is* the storage grain of
  `cc_hour_agg`, so peak and average are stored columns. It pins the cube sentinels
  `platform='*' AND country='*' AND content_id=-1`. That is the payoff of hour-clipping
  ([ADR 0003](adr/0003-hour-clipped-interval-splitting.md)): a day peak reads 24 rows, not 1,440.

---

## 5 · `SonyLIV pipeline health` — ClickStack observing **us**

```
 ┌──────────────────┬──────────────────┬──────────────────────┐
 │ Watermark sealed │ Hour tier: last  │ Raw→sealed gap       │
 │ lag (s)          │ hour complete?   │ (min, abs)           │
 │ NEGATIVE = HEALTHY│ 1/0             │                      │
 └──────────────────┴──────────────────┴──────────────────────┘
 ┌──────────────────────────┬─────────────────────────────────┐
 │ Build-stage duration ms  │ Build-stage rows written        │
 ├──────────────────────────┼─────────────────────────────────┤
 │ Reconcile gate runs+ms   │ Query exceptions (flat 0)       │
 └──────────────────────────┴─────────────────────────────────┘
```

**The counter-intuitive one, and the reason this panel has a long title:**

```
  sealed_lag_s  =  raw_watermark − sealed_watermark

  NEGATIVE  ▸ the sealed tier LEADS the raw tier ▸ HEALTHY
            an interval's close delta lands at end-minute + 1, and `end`
            already carries TAIL_S = 60 s of grace, so on a caught-up model
            the sealed watermark sits up to ~2 minutes AHEAD of the newest
            event. Measured healthy steady state: −116 s.

  POSITIVE  ▸ the finalizer is genuinely behind.
```

Anything in `[−120 s, 0]` is caught up. A reader who assumes "negative lag = broken" will raise a
false alarm; that is why the sign convention is in the tile name.

The build-stage tiles read `system.query_log` and identify each stage by the **tables it touched**,
not by a label — e.g. the interval build is an `Insert` touching both `session_intervals` *and*
`ev_raw`, while the delta build touches `cc_minute_delta` and `session_intervals` but **not** `ev_raw`.
So the timings are what ClickHouse actually measured, never re-timed by a wrapper.

⚠ **Known defect:** `sonyliv observe` currently reports `reconcile pass=false` while the gate is green
(17,028 minutes, 0 mismatched). The Go parser expects the pre-`81c0161` five-column table; the gate now
emits `ord` and `scope`, so it parses zero rows and correctly calls "no evidence" a failure. Queued as
**Q1** in [WORKTREE_QUEUE.md](WORKTREE_QUEUE.md). The *dashboard* tiles above are unaffected — they read
`query_log` directly.

---

## 6 · `SonyLIV query cost` — what our queries *read*

```
 ┌──────────────────────────┬─────────────────────────────────┐
 │ Latency p95 / p50 / max  │ BYTES read (total + max single) │
 ├──────────────────────────┼─────────────────────────────────┤
 │ Rows read                │ Peak memory per bucket          │
 └──────────────────────────┴─────────────────────────────────┘
 ┌────────────────────────────────────────────────────────────┐
 │ Heaviest query shapes by bytes read  (table)               │
 └────────────────────────────────────────────────────────────┘
```

This dashboard exists because of one line in the problem statement: *"Judges will look at what your
queries read, not just how fast they return."* Latency alone is cheap to fake with a warm cache; bytes
read is not.

All tiles filter `type = 'QueryFinish' AND query_kind = 'Select'` and
`arrayExists(t -> startsWith(t, 'sonyliv.'), tables)` — so they measure **our** queries, not
ClickHouse's internal traffic. The heaviest-shapes table groups by `substring(query, 1, 80)`, which is
enough to identify a shape without exploding on parameter values.

---

## 7 · Operating notes

| Trap | What happens | Fix |
|---|---|---|
| **Default time range** | every panel empty — data ends 2026-07-26 | set **2026-07-14 → 2026-07-26** *before* screen-sharing |
| **Summing `concurrent` across dimensions** | double counts: a session appears under several content_ids | use the `_total` sources, which re-merge the underlying states |
| **Users vs sessions** | the user source exposes `concurrent_users`, not `concurrent` | a tile selecting the wrong column silently returns nothing |
| **Zooming out on the drilldown** | `count_distinct` per bucket stops meaning "concurrency" | quote it as "distinct sessions active in the bucket" |
| **Hindi appears four times** | un-normalised source values | real data; ADR 0011 exists but is not deployed |

**Everything is scripted.** `tools/clickstack-cloud.sh` provisions sources, dashboards and saved
searches over the Cloud control-plane API and is idempotent — a re-run **PUTs** the dashboard so the
script stays the source of truth and a hand-edit in the UI cannot silently outlive it.

One value the API cannot yield on an empty service is the `connection` id; get it once from the
clickstack MCP (`clickstack_list_sources` returns a top-level `connections` array even when `sources`
is empty) and put it in `.env` as `CLICKSTACK_CONNECTION_ID`.

## 8 · Provenance

Captured live via the clickstack MCP against the hosted service: `clickstack_list_sources` for the 24
sources and one connection, `clickstack_get_dashboard` for all six dashboards and their 41 tiles. Every
panel name, source binding, value expression, aggregation and filter above was read from the running
configuration rather than from the provisioning script's intent — the two have drifted before.
