# DATA_DICTIONARY — the SonyLIV event stream

> **Summary:** Field-by-field reference for `ch-hackathon-raw-data.csv` (905,558 events) and
> `ch-hackathon-content-data.csv` (~33K titles), plus the **measured** shape of the provided file and
> the eight traps that decide whether the model survives the unseen day. `event_timestamp` is epoch
> **milliseconds**. Backgrounding is **universal** (every session has one) and background/foreground
> events are **not guaranteed to pair**. Read [#traps](#traps) before writing any interval logic.

Both files are gitignored (223 MB). Get them with `tools/fetch_data.sh` — checksum-pinned against the
[organiser repo](https://github.com/sidagarwal04/click-a-thon-2026/tree/main/SonyLiv/data).

## Raw events — `ev_raw`

| Column | Type | Notes |
|---|---|---|
| `video_session_id` | String | session-level concurrency derives from this |
| `user_id` | String | user-level concurrency derives from this (a user may have several sessions) |
| `content_id` | **Int64** | join key to `content_dim`; filter dimension. **NOT UInt64** — see trap 5 |
| `event_type` | LowCardinality(String) | see the enum below |
| `event` | LowCardinality(String) | the specific event within the type |
| `event_timestamp` | DateTime64(3) | **source is epoch MILLIS** — divide by 1000 on load |
| `platform` | LowCardinality(String) | filter dimension · 10 distinct |
| `app_version`, `player_version` | LowCardinality(String) | filter dimensions |
| `country` | LowCardinality(String) | filter dimension · **only 1 value in the provided file** |
| `audio_language`, `subtitle_language` | LowCardinality(String) | filter dimensions |
| `session_start_epoch` | DateTime64(3) | session start, repeated on every event of the session |

### `event_type` enum, with measured counts

| event_type | count | share | meaning |
|---|---:|---:|---|
| `VideoHeartbeat` | 843,600 | 93.16% | periodic; statement says 60s, observed dominant cadence is 40s — activity evidence, not proof without state |
| `AppBackgrounded` | 14,700 | 1.62% | app went to background — **not guaranteed** |
| `AppForegrounded` | 14,321 | 1.58% | app returned — **not guaranteed** |
| `VideoPlay` | 10,883 | 1.20% | playback started/resumed |
| `VideoSessionEnd` | 10,881 | 1.20% | session closed |
| `VideoSessionStart` | 10,880 | 1.20% | session opened |
| `VideoError` | 293 | 0.03% | playback error |

## Content dimension — `content_dim`

`content_id` · `title` · `video_type` · `category`. Small and static, so it is also loaded as a
**dictionary** — `dictGet` measured 34× faster than a `JOIN` on a comparable workload.

It is a **snapshot dimension** in this benchmark, not a slowly changing dimension. The source gate allows
an exact reload but rejects any one `content_id` with conflicting title/video-type/category values. Otherwise
the `ReplacingMergeTree` storage engine could select a value during an asynchronous merge, making a
`video_type` dashboard filter nondeterministic. A production SCD needs an effective-time/version contract
and the serving query must state whether it means video type at watch time or type as currently catalogued.

## Measured shape of the provided file

```
sessions               10,866
events                905,558
span                   2026-07-14 15:43:58 → 2026-07-26 11:30:04  (283.8 h ≈ 11.8 days)
distinct content_id     3,357
distinct platform          10
distinct country            1        ← do not hard-code around this
avg heartbeats/session   77.6        ← ≈ 78 min average session
sessions with a background event  10,866  (ALL of them)
sessions that background and never return   418
sessions with no VideoSessionEnd        0   ← but see trap 3
```

## <a id="traps"></a>The eight traps

**1 · Background/foreground events do not pair.** 14,700 backgrounds vs 14,321 foregrounds — **379
unmatched**, and 418 sessions background and never come back. The dictionary says outright they
"are not guaranteed events and sometimes depend on the system." Any model that reconstructs inactivity
by pairing `AppBackgrounded` → `AppForegrounded` is wrong on ~4% of sessions here, and wrong by a
different amount on the unseen day. **Use the events as hard stop gates and fail closed if the corresponding
foreground signal is missing.** An `AppForegrounded`/`resume` transition changes state eligibility; only a
fresh heartbeat after both gates are active restarts playback. In this corpus, 83 sessions have a heartbeat
after their final unmatched background; counting those as foreground from heartbeat alone would reintroduce
the failure mode the gate prevents.

**2 · Backgrounding is universal, not an edge case.** Every one of the 10,866 sessions has at least one
background event. Foreground-only exclusion is the entire problem, not a correction term.

**3 · The provided file has ZERO open sessions — the unseen day will have them.** The statement is
explicit: *"sessions in the dataset include ones still open when the day ends and heartbeats that keep
arriving."* Tuning on this file will not exercise that path at all. Test it by truncating the file at
an arbitrary timestamp and re-running.

**4 · `content_id` can be NEGATIVE.** `content_dim` contains exactly one row with
`content_id = -987654322` (1 of 33,464; zero such rows in the event file). A `UInt64` column fails the
load with `Code: 6 CANNOT_PARSE_NUMBER` on row 1193. Use **`Int64`**. This is a planted poison row —
assume the unseen day has one too, possibly in the *event* stream where it would also break joins.

**5 · One country, ten platforms.** `country` has a single value here, so a bug in country filtering is
invisible in testing and fatal on the unseen day. Always test filters against `platform` too.

**6 · Event identity, lifecycle and dimensions are not immutable.** There are **4,209 exact duplicate rows** but
no source event id, so the derived model removes exact payload retry copies while retaining raw data.
Also, 95 sessions change platform and one changes content id. An interval must split when a serving
dimension changes; grouping a session and selecting `any(platform)` assigns activity arbitrarily.
The supplied file has zero `video_session_id` values spanning multiple `session_start_epoch` values; do
not assume this for live input. A reused id would join two playback lifecycles and poison foreground/
pause state, so production requires `session_incarnation_id` (or an enforced equivalent).

**7 · Bulk-load time is not arrival telemetry.** The supplied corpus has exactly one `ingested_at` value
(`2026-08-01 08:56:02.042`) across all 905,558 rows. It records when we loaded the CSV, not when devices
or the source delivered events. Never calculate a production watermark percentile from it; use it only for
finalizer replay mechanics in this local exercise.

**8 · App-state scope is supplied per session, not inferred from `user_id`.** 61 users have overlapping
session lifetimes (18,211 overlapping session pairs), and 120 session ids carry more than one `user_id`.
Yet no `AppBackgrounded`/`AppForegrounded` timestamp is shared by two overlapping sessions of the same user
in this corpus. That supports treating the delivered app-state event as attached to its
`video_session_id`, while proving that `user_id` is neither a player-instance key nor a safe state scope.
At production, require `player_instance_id` and explicit state scope if one app transition can govern
multiple concurrent playback sessions.

## Heartbeat payload taxonomy is not playback state

`VideoHeartbeat` is a transport envelope, not a single semantic action: the supplied file contains 41
distinct `event` values inside it. Only the explicitly documented `pause` and `resume` values change the
playback-state gate. Buffering, seeking, ad, download, rendition, and network payloads remain liveness
signals; treating their names as stops without a producer contract would invent inactivity and alter the
private-ground-truth metric.

| Ambiguous payload family | Supplied-data observation | Model decision |
|---|---|---|
| `speed-pause` / `speed-resume` | 380 pairs; the paired records share a timestamp | configuration telemetry, not playback pause |
| `AdPause` / `AdResume` | 45 / 27; following heartbeat median is 2 / 6 seconds | ad telemetry, not a viewer playback stop without an explicit specification |
| `download_asset_play_stop` | 10; next payload is usually at the same timestamp | download lifecycle, not the streaming session stop |
| `BufferStart`, `Seek`, network/quality events | frequent, interleaved with active heartbeats | activity/liveness evidence only |

The source-contract gate rejects unknown **event types**, but intentionally permits new heartbeat payloads
as opaque liveness events. An unseen payload must be promoted to a state transition only with producer
semantics and a sensitivity/reconciliation result; otherwise it cannot silently change what “watching” means.

## Traffic is extremely concentrated — this is a live-event dataset

```
2026-07-26 10:00   425,108 events   ← 47% of the entire file in ONE hour
2026-07-26 11:00   374,053 events   ← another 41%
2026-07-26 09:00    17,806 events
2026-07-14         152 events, then a GAP until 07-21
```

**88% of all events fall in two consecutive hours.** This is a live-sport concurrency spike, and it is
the demo: the curve should climb steeply into 10:00 on 26 July. It also means any benchmark run on a
random hour is measuring almost nothing — always state which window a number came from.

## Loading

`tools/load.sh` handles the millisecond conversion and column typing. It expects the CSVs in `data/`
(gitignored — they are 222 MB).
