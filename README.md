# Foreground-only concurrency at streaming scale

> Click-a-thon India 2026 · **SonyLIV track** · ClickHouse as the primary datastore, ClickStack as the
> observability integration.

**The question:** how many active playback **sessions** are actually watching right now? An open app is
not a watching viewer. This system counts only truly active playback — excluding backgrounded, paused
and heartbeat-missing periods — and answers minute-grain, filtered concurrency queries from a serving
layer, not by rescanning session history. Distinct-person concurrency is a separate, non-additive metric.

## Run it

```bash
cp .env.example .env          # fill in CH_PASSWORD_LOCAL and AGENT_PASSWORD
docker compose up -d
tools/fetch_data.sh           # downloads the 223 MB of CSVs, checksum-verified
tools/load.sh
tools/materialize.sh --replace # builds state-gated intervals and serving deltas
tools/bootstrap-finalizer.sh --replace # verifies the matching per-session correction baseline
tools/finalize.sh             # incrementally publishes late/open-session corrections
tools/refresh-tail.sh         # publishes the exact newest 15-minute serving snapshot
tools/reconcile.sh             # proves five raw-derived minutes equal the serving layer
tools/verify-model.sh          # checks stops, dimension handoffs, and sampled delta arithmetic
```
The datasets are **not in this repo** — they are 223 MB of organiser-provided data. `fetch_data.sh`
pulls them from the [organiser repo](https://github.com/sidagarwal04/click-a-thon-2026/tree/main/SonyLiv/data)
and verifies each against a pinned sha256, so a truncated download fails there rather than surfacing
as wrong concurrency numbers later. Already have the files? `tools/fetch_data.sh --verify` checks them
without re-downloading.
Then verify before trusting anything — a failed init script leaves a container that looks healthy:
```bash
tools/ch "SELECT name FROM system.tables WHERE database='default'"
```

## The model, in one picture

```
 ev_raw (MergeTree, dashboard-oriented key + session projection)
   │   raw events: session start/end, observed ~40s heartbeat cadence, background/foreground
   │
   ├─▶ session_intervals (MergeTree)               ← ACTIVE ranges per session,
   │      state-gated by foreground AND playing,      split by hard stop or heartbeat gap.
   │      background/pause terminate immediately;      after foreground/resume, a fresh heartbeat restarts.
   │
   ├─▶ cc_minute_delta (AggregatingMergeTree)      ← +1 on open, −1 on close, per minute
   │      ORDER BY (platform, country, content_id, minute)   per dimension combination
   │         concurrency(M) = running sum inside M's hour
   │         peak(range)    = max of that running sum  ← NOT summable across dimensions
   │
   ├─▶ session_delta_base + correction stage         ← touched-session replacement state,
   │      staged runs are invisible until published;    safe late-event correction overlay.
   │
   ├─▶ exact_tail_minute_stage                       ← bounded full snapshot after a finalizer run;
   │      newest event-time minutes are exact, and a stale snapshot is automatically disabled.
   │
   └─▶ v_concurrency_change                         ← compact, hour-local change points;
          query only the filtered range and             never explode all history by minute.
```

Why deltas and not per-minute explosion: exploding each session into one row per active minute is
O(sessions × minutes) and collapses at scale. Deltas are O(intervals).

Why state-gated heartbeats: background/foreground markers are unpaired, so they cannot independently
reconstruct playback; yet 4,503 heartbeats occur while backgrounded and 94,463 while paused. A
heartbeat therefore proves activity only while both state machines are active. See
[ADR 0007](docs/adr/0007-state-gate-heartbeats.md) and [research](docs/RESEARCH.md).

Serve a minute curve or exact minute-weighted peak/average without revisiting raw events:

```bash
tools/query-concurrency.sh --from '2026-07-26 10:50:00' --to '2026-07-26 11:05:00' \
  --platform ANDROID_PHONE --summary
```

`from` and `to` are inclusive UTC minute boundaries. Omit a dimension flag to aggregate across it.

## Where things are

| | |
|---|---|
| Router for agents | [AGENTS.md](AGENTS.md) |
| How work flows / the gates | [AGENT_WORKFLOW.md](AGENT_WORKFLOW.md) |
| Data shape and **the seven traps** | [docs/DATA_DICTIONARY.md](docs/DATA_DICTIONARY.md) |
| Verified ClickHouse facts | [docs/VERIFIED.md](docs/VERIFIED.md) |
| Scripts | [tools/README.md](tools/README.md) |
| Task queue | [TODOS.md](TODOS.md) |

## Licence

MIT — see [LICENSE](LICENSE).
