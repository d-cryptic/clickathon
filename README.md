# Foreground-only concurrency at streaming scale

> Click-a-thon India 2026 · **SonyLIV track** · ClickHouse as the primary datastore, ClickStack as the
> observability integration.

**The question:** how many people are *actually watching* right now? An open app is not a watching
viewer. This system counts only truly active playback — excluding backgrounded, paused and
heartbeat-missing periods — and answers minute-grain, filtered concurrency queries from a serving
layer, not by rescanning session history.

## Run it

```bash
cp .env.example .env          # fill in CH_PASSWORD_LOCAL and AGENT_PASSWORD
docker compose up -d
tools/fetch_data.sh           # downloads the 223 MB of CSVs, checksum-verified
tools/load.sh
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

## Develop it

Go 1.26 pinned by devbox, entered by direnv, driven by make. Full detail in [docs/GO.md](docs/GO.md).

```bash
direnv allow                  # once — pinned toolchain + .env, no manual PATH
make hooks                    # fixing pre-commit hook
make ci                       # tidy, vet, lint, test, build — same as GitHub Actions
make verify                   # run the CLI against the Cloud service
```

## The model, in one picture

```
 ev_raw (MergeTree, ORDER BY (video_session_id, event_timestamp))
   │   raw events: session start/end, 60s heartbeats, background/foreground
   │
   ├─▶ session_intervals (ReplacingMergeTree)      ← ACTIVE ranges per session,
   │      derived from HEARTBEAT GAPS                 closed by gap > threshold.
   │      bg/fg corroborate, never decide             Late heartbeats EXTEND, not duplicate.
   │
   ├─▶ cc_minute_delta (AggregatingMergeTree)      ← +1 on open, −1 on close, per minute
   │      ORDER BY (platform, country, content_id, minute)   per dimension combination
   │         concurrency(M) = running sum of deltas ≤ M
   │         peak(range)    = max of that running sum  ← NOT summable across dimensions
   │
   └─▶ cc_minute_stateless (AggregatingMergeTree)  ← session-INDEPENDENT baseline,
          uniqState of sessions seen active           always fresh, less accurate.
          The gap between the two IS the headline: it is the backgrounded time we exclude.
```

Why deltas and not per-minute explosion: exploding each session into one row per active minute is
O(sessions × minutes) and collapses at scale. Deltas are O(intervals).

Why heartbeat gaps and not background events: the data dictionary says those events are **not
guaranteed**, and the provided file proves it — 14,700 backgrounds vs 14,321 foregrounds, and 418
sessions that background and never return. See [ADR 0001](docs/adr/0001-heartbeat-gaps-over-background-events.md).

## Where things are

| | |
|---|---|
| Router for agents | [AGENTS.md](AGENTS.md) |
| How work flows / the gates | [AGENT_WORKFLOW.md](AGENT_WORKFLOW.md) |
| Data shape and **the four traps** | [docs/DATA_DICTIONARY.md](docs/DATA_DICTIONARY.md) |
| Verified ClickHouse facts | [docs/VERIFIED.md](docs/VERIFIED.md) |
| Scripts | [tools/README.md](tools/README.md) |
| Task queue | [TODOS.md](TODOS.md) |

## Licence

MIT — see [LICENSE](LICENSE).
