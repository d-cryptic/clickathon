# EXPLAINER — the whole problem in layman terms

> **Summary:** A from-scratch, plain-English walkthrough of what we were asked to build and why the
> obvious approach is wrong, written for someone who has never seen the repo — a new teammate, a judge,
> or the author at hour 18. Section A is the **ask**; B is **why it is hard**; C is **what we built**;
> D is **why this approach and what we rejected**; E is **proven vs. missing**. Every number here is
> measured against the graded ClickHouse Cloud service, never hand-computed. Where a number is
> load-bearing, the query that produced it is shown. Deeper treatments:
> [ARCHITECTURE.md](ARCHITECTURE.md) for the model, [adr/](adr/) for the decisions,
> [DATA_DICTIONARY.md](DATA_DICTIONARY.md) for the field-level detail.

**Status:** A–E complete. B is measured against a **fresh reload of both CSVs**
into a local `csv_audit` database with every column typed `String`, so nothing was coerced or rejected
by the parser — that is how the findings marked 🔴 were found at all.

---

# A · What we were asked to build

## The business question, in one line

> *A cricket match is streaming. How many people are watching **right now**?*

That number decides how many servers to spin up, what to charge advertisers, and whether the content
is working. Per the problem statement it is "both the most-asked question in the building and one of
the hardest to answer correctly."

## Why it isn't just "count open sessions"

Because **the app being open is not the same as someone watching.**

Take one viewer, Ravi. He opens SonyLIV at 8:00pm and closes it at 9:00pm. His *session* is 60
minutes long. But:

```
8:00 ─────────────────────────────────────────────────────── 9:00
     ████████████  ▒▒▒▒▒▒▒▒  ██████████  ░░░░░░░░░░░  ████████
       watching     phone     watching     PAUSED      watching
       20 min      in pocket    10 min      15 min       5 min
                    10 min
                   (backgrounded)

     NAIVE  : "Ravi watched for 60 minutes"
     TRUTH  : "Ravi watched for 35 minutes"
```

Two different lies hide in that gap:

- at **8:25pm** the naive count says Ravi is watching — his phone is in his pocket
- at **8:45pm** the naive count says Ravi is watching — he hit pause and walked away

Multiply that across millions of viewers and you have over-sold your ad inventory and
over-provisioned your servers. **The whole problem exists to kill that over-count.**

On our actual file the over-count is not a rounding error: naive session-span counts **2,976.9 hours**
of watch time against the foreground-only model's **1,949.3 hours** — **34.5% of apparent watch time
is backgrounded or paused**. At the peak minute, 3,708 naive against **2,887** actual.

## What we are actually handed

Not a helpful `is_watching = true` column. Just a stream of breadcrumbs:

```
 Ravi's session, as events
 ────────────────────────────────────────────────────────────
 VideoSessionStart    8:00:00
 VideoPlay            8:00:03
 VideoHeartbeat       8:00:15   ┐
 VideoHeartbeat       8:00:31   ├─ "I'm still here" pings
 VideoHeartbeat       8:00:44   ┘
 ...
 AppBackgrounded      8:20:00   ← phone goes in pocket
      ( silence — the pings stop )
 AppForegrounded      8:30:00
 VideoHeartbeat       8:30:02
 ...
 pause                8:40:00   ← hits pause
 VideoHeartbeat       8:41:19   ← ⚠ the pings KEEP COMING
 VideoHeartbeat       8:42:44   ⚠
 resume               8:55:00
 ...
 VideoSessionEnd      9:00:00
```

Our job is to **reconstruct "was he actually watching?"** from those breadcrumbs — for 10,866
sessions and 905,558 events in the sample file, and for a petabyte-class stream in the design we are
asked to defend.

## What "concurrency" means, precisely

For every single minute, how many people were actively watching during it:

```
                8:00   8:10   8:20   8:30   8:40   8:50   9:00
 Ravi           ████████████         ██████████        ████
 Priya                ███████████████████████████
 Arun                        ██████████████████████████████
                ─────────────────────────────────────────────
 CONCURRENCY      1      2      2      2      2      2      1
                                  ↑
                        this curve IS the deliverable
```

From that curve you read **peak** (the highest it ever got over a range) and **average** (the area
under it ÷ the time span). And you must be able to slice it: *peak concurrency on Android, in India,
for this match, this hour.*

## The five things the organiser's spec demands

From [`upstream/`](upstream/) — the three files that are the contract, never edited:

```
 1 · INGEST         raw playback events, timestamped by when they HAPPENED
                    (not when they arrived)
        │
 2 · ENRICH         join each event to content metadata
                    content_id → title, video_type, category
        │
 3 · FILTER + CLEAN foreground-only filtering
                    deduplicate late or repeated events
        │
 4 · AGGREGATE      ┌ foreground concurrency      ← the headline
                    ├ content-level concurrency   ← demand by title
                    └ time-window trend           ← rolling / fixed windows
        │
 5 · PUBLISH        "continuously updated aggregates for downstream consumers"
```

...and running alongside all of it, a comparison the spec insists on:

```
        SESSION-AWARE                    SESSION-INDEPENDENT
   "reconstruct each viewer's       "count active viewers straight
    session, then count"             from event state, no sessions"
        accurate, expensive               cheap, approximate
              └───────────── COMPARE BOTH ─────────────┘
                  "to validate accuracy and
                   operational trade-offs"
```

## Four qualities it is graded on

| | What it means in practice |
|---|---|
| **Correct** | matches a **private** answer key we never see. Foreground-only means foreground-only. |
| **Fast** | dashboard-speed, reading from a purpose-built serving table — *not* rescanning session history per query |
| **Update-friendly** | sessions are still open and heartbeats keep arriving; absorb them **incrementally**, never by rebuilding |
| **Explained** | defend every trade-off out loud — schema, ordering keys, aggregation strategy |

Two hard constraints on top: **ClickHouse must be the primary datastore**, and we must *meaningfully*
integrate one of ClickStack / Langfuse / LibreChat — "superficial inclusion won't count."

And the sting in the tail: **an unseen day of data is released in the final hours**, and our answers
on it carry significant weight. We are not building for the file we have — we are building for a file
we have never seen. See [DATA_DICTIONARY.md#traps](DATA_DICTIONARY.md#traps).

## A in one sentence

> Turn a stream of breadcrumbs into a minute-by-minute "who is really watching" curve — fast enough
> to serve dashboards, honest enough to match a hidden answer key, and flexible enough to absorb data
> that has not arrived yet.

---

# B · What is actually in the data

> Everything below was measured on a **fresh reload of both CSVs** into `csv_audit`, every column typed
> `String` so the parser coerced nothing. Items marked 🔴 **contradict what this repo currently
> documents** and are the reason for re-reading the raw files rather than trusting the loaded tables.

## B.0 · The two files

```
 ch-hackathon-raw-data.csv      905,558 events    10,866 sessions   9,618 users
                                 13 columns · 233 MB · 2026-07-14 → 07-26

 ch-hackathon-content-data.csv   33,464 titles    4 columns · 1.2 MB
                                 only 3,357 of them (10%) are ever watched
```

`wc -l` reports one more of each — that is the CSV header. Every number in this repo is built on
**905,558**.

## B.1 · 🔴 The heartbeat has a pulse, and it is 40 seconds

[ADR 0007](adr/0007-gate-answers-pause-needs-explicit-handling.md) records the heartbeat as aperiodic —
*"bursty telemetry, p50 inter-arrival 0s, there is no cadence."* That conclusion came from measuring
all 41 `VideoHeartbeat` sub-events **mixed together**. Separated, three of them are metronomes.

```
 ALL VideoHeartbeat events, mixed:      gap p50 = 0.14 s   → "no cadence" ✗

 ONE telemetry stream at a time:
   network-activity   ●————40s————●————40s————●————40s————●    177,485 events
   buffer-health        ●————40s————●————40s————●————40s————●  167,460
   video-resize           ●————40s————●————40s————●————40s———  141,250
   network-bandwidth  ●——————————120s——————————●               30,637

        p50 = p90 = 40.0 s for each of the top three, independently

 Gap histogram over ALL events — the MODE is the 40-second bucket:
   40 s  ████████████████████████████████  100,099 gaps
    1 s  █████████████                      40,910
   30 s  ████                               14,167
```

Consequences: `GAP_S = 150` is 3.75 missed beats rather than "3× a p99 of 49 s", and `TAIL_S = 60` was
justified as "one cadence" — the cadence is **40**. Full dossier and the question to ask:
[doubts/01](../doubts/01-heartbeat-cadence.md).

## B.2 · What one session looks like

```
 events per session   min 6 · p50 53 · p90 180 · p99 434 · max 1,803
 duration             p50 11.9 min · p90 33 min · p99 74 min · max 43.6 HOURS
 zero-length 0 · single-event 0
```

🔴 [DATA_DICTIONARY.md](DATA_DICTIONARY.md) says *"avg heartbeats/session 77.6 ← ≈ 78 min average
session."* That inference assumed one beat per minute. **The median session is 11.9 minutes.**
[ADR 0003](adr/0003-hour-clipped-interval-splitting.md)'s "~1.3 hour crossings per session" inherits
the same error.

Two things are exactly reliable and can be trusted as keys:

```
 session_start_epoch  constant within all 10,866 sessions, and EXACTLY equal to
                      the VideoSessionStart timestamp (max difference: 0 ms).
                      NOT unique — 18 values are shared by 2 sessions each.
                      Currently UNUSED by the model; on the unseen day it is the
                      only reliable start for a session truncated at the window edge.

 IDs                  all 905,558 video_session_id and user_id values are 64-char
                      UPPERCASE hex, zero malformed. Lowercase one side of a join
                      and you get zero matches.
```

## B.3 · The two ways of not-watching

```
                       pings/min      median window     longest window
 ─────────────────────────────────────────────────────────────────────
 ACTIVELY WATCHING       4.72              —                 —
 BACKGROUNDED            0.047          35 seconds        39.6 hours
 PAUSED                  0.756          20 seconds        42.4 hours
```

Backgrounding suspends the app, so the player goes **silent** and a gap detector sees it. Pausing
leaves the app alive and still chattering — **one ping every ~79 s**, which slips under any sane
threshold. That asymmetry is the entire reason the model needs two signals, and it is confirmed
exactly as [ADR 0007](adr/0007-gate-answers-pause-needs-explicit-handling.md) recorded it. The
*medians* are new: most interruptions are seconds long, but the tail runs to days.

## B.4 · 🔴 `resume` is overloaded — and it is the largest open number in the model

```
 resume → resume  consecutive     9,958      ← a resume that resumes nothing
 pause  → pause   consecutive       560
 sessions whose FIRST pause/resume event is a resume     900
 pauses with no later resume at all    6,124  (22.4%)
```

`sql/30_build_intervals.sql` closes a paused window at `arrayFirst(x -> x > p, resumes)` — the first
resume after the pause. If that resume is spurious (fired by a seek or buffer recovery), the window
closes early and the remainder is booked as watch time.

Measured end to end over the real file:

| rule | paused time counted |
|---|---|
| **A — shipped** (close at first resume) | **816.1 h** |
| **B** (a burst of resumes is one un-pause) | **1,005.2 h** |
| **difference** | **189.2 h — 9.7% of the 1,949.3 h we report** |

That is **nearly double** the unclosed-pause question (99.3 h / 5.09%) that ADR 0007 calls "the single
largest unresolved number in the model." It is not. This is. Dossier:
[doubts/02](../doubts/02-resume-semantics.md).

The bg/fg ledger is imperfect too: **109** `bg→bg` and **45** `fg→fg` illegal same-state transitions
across 132 sessions.

## B.5 · Sessions do not stop when they end

```
 239 sessions emit 802 events AFTER their own VideoSessionEnd
 worst case 2,080.6 s late (~35 min)

 what arrives late:  239 × AppBackgrounded  ← EXACTLY ONE per straggler session
                     275 × network-bandwidth   88 × Seek     43 × pause
                      38 × resume              28 × AppForegrounded
                      13 × VideoPlay        ← an "ended" session starts PLAYING
```

The `AppBackgrounded` count is a discovered *pattern*, not noise: the app fires "end", then fires
"backgrounded". And **4 sessions carry two genuinely different `VideoSessionEnd` timestamps**, up to
11 minutes apart — for those, "when did this session end" has no single answer.

## B.6 · It is one day, not twelve

```
 07-14 │▏                                                        152
 07-15 │  ┐
  ...  │  ├─ SIX DAYS WITH ZERO EVENTS
 07-20 │  ┘
 07-21 │▏                                                         65
 07-22 │▎                                                      6,025
 07-23 │▎                                                      8,195
 07-24 │▍                                                     11,136
 07-25 │█                                                     30,097
 07-26 │████████████████████████████████████████████████    849,888   93.85%

 inside 07-26:  10:00 → 425,108   11:00 → 374,053   (file ends 11:30:04)
                two clock hours = 799,161 events = 88.25% of everything
```

Any benchmark run on a randomly chosen hour measures almost nothing. Every latency number must state
its window.

## B.7 · 🔴 The filter dimensions are not normalised

```
 audio_language — 41 values. Hindi is FOUR of them:
   hin 610,889 │ HIN 69,033 │ hin-hindi 23,095 │ hin-Hindi 507   = 703,524 rows
   jap 1,374 and jpn 386 are both Japanese
   -soundhandler (13 rows) is not a language
   '' empty 1,991

 subtitle_language — 11 values, 91.6% sentinel
   UNK 753,258 │ UND 63,768 │ off 28,982 │ OFF 10,842 │ unk 9,902 │ und 58 │ '' 2,006

 player_version — _ADE/_adE, _ADNE/_adNE     app_version — 5.0.36 vs 5.0.36.00
 platform       — Mweb is mixed-case; the other 9 are UPPER_SNAKE
 country        — ONE value, 'india', lowercase. A filter bug here is INVISIBLE.
```

`WHERE audio_language = 'hin'` returns 610,889 of 703,524 Hindi rows. **This lands directly on
ADR 0008**, which promotes these four columns to filter dimensions — the key-order and row-count
analysis there is sound, but the *values* going into those keys need a normalisation decision first.

## B.8 · The content catalog

```
 33,464 titles · content_id is a true primary key (33,464/33,464 unique)
 0 orphans — every event's content_id has a catalog row  ✓ (true of THIS file, not a contract)
 poison row -987654322 exists, has 0 events, and kills a UInt64 column

 video_type   vod 32,182 (96%) │ '' EMPTY 1,089 (3.25%) │ live 193 (0.6%)
              → 25,810 events (2.85%) land on the nameless third bucket

 title is NOT a key   2,773 titles shared by 2–4 content_ids
                      1,418 collisions span multiple CATEGORIES
                      → v_concurrency_minute_title merges distinct assets
```

Dossier: [doubts/03](../doubts/03-content-catalog.md).

## B.9 · Duplicates, ordering, and ties

```
 4,209 byte-identical duplicate rows                            (0.46%)
 4,210 duplicates on (session, ts, event_type, event)
       the +1 is the ONE group that differs — in subtitle_language, UNK vs OFF
 863 sessions affected · up to 6 copies of one event

 THE FILE IS NOT TIME-SORTED
   71,171 timestamp inversions in physical read order
   63,334 of them INSIDE a single session

 23.67% of adjacent event pairs share the EXACT SAME MILLISECOND
```

`evidence/dedup.txt` proves the duplicates are inert for concurrency. The **ties** are the live hazard:
the model truncates to whole seconds before splitting runs, so ties are denser still, and
`sql/90_reconcile.sql` already carries a scar from two orderings resolving them differently.

## B.10 · Scorecard

| | |
|---|---|
| **Confirmed exactly** | 0 orphans · poison row · 0 negative clock skew · `session_start_epoch` reliable · the 0.047 / 0.756 / 4.72 asymmetry · 88% in two hours · 4,210 duplicates · `pause`/`resume` lowercase only, under `VideoHeartbeat` only |
| 🔴 **New, and it moves the model** | 40-second cadence exists → `TAIL_S` reasoning is wrong · `resume` overloaded → 9.7% · dimensions un-normalised · 23.67% same-millisecond ties · title collisions |
| 🔴 **Our docs are wrong** | "≈78-minute average session" (11.9 min median) · "no cadence exists" (40 s) · "one outlier user with 297 sessions" (301) |
| **Definitions need pinning** | "backgrounds and never returns" = 418 (count-based) or 344 (last-event-based)? Both appear in our docs. |

**B in one sentence:** the data has a hidden 40-second heartbeat we told ourselves did not exist, a
`resume` event that means four different things, and filter dimensions where one language is spelled
four ways — and none of those three were in our docs before this pass.

# C · What we built, what is broken, and how accurate it really is

## C.1 · The machine, in one picture

```
   ch-hackathon-raw-data.csv                    ch-hackathon-content-data.csv
            │ 905,558 events                              │ 33,464 titles
            ▼                                             ▼
     ┌─────────────┐                              ┌──────────────┐
     │   ev_raw    │                              │ content_dim  │──▶ dict_content
     └──────┬──────┘                              └──────────────┘   (COMPLEX_KEY_HASHED,
            │                                                          signed keys)
            │ ① "when was each viewer ACTUALLY watching?"
            │    runs split on 150s gaps  MINUS  explicit pause windows
            ▼
     ┌──────────────────────┐
     │  session_intervals   │  30,769 rows · one row per active stretch
     └──────┬───────────────┘  all 7 raw dimensions (ADR 0008)
            │
            │ ② "turn stretches into +1 / −1, clipped to each hour"
            ▼
     ┌──────────────────────┐
     │   cc_minute_delta    │  ~28,000 rows ← THE SERVING LAYER
     └──────┬───────────────┘  concurrency = running sum WITHIN the hour
            │
     ┌──────┴───────┬──────────────┬────────────────┐
     ▼              ▼              ▼                ▼
 cc_hour_agg   9 window views   content views   v_concurrency_*
 peak+integral  rolling 5/15/60  by title /       the curve a
 8-level cube   tumbling, ragged  category         chart reads

 ── separately, straight from ev_raw ──
 cc_minute_stateless  ← the session-INDEPENDENT baseline
 cc_user_minute       ← distinct USERS per minute (uniqExact)
```

Why this shape at all:

```
 explode every session to one row per active minute   ~185,000,000 rows
 our delta serving layer                                  ~28,000 rows
                                                          ~6,600× smaller
```

## C.2 · Layer by layer

**① `session_intervals` — "when was this person really watching?"** Sort a session's events, cut
wherever silence exceeds `GAP_S = 150 s` (a backgrounding), then subtract the explicit pause windows.

```
 raw events   ●●●● ●●●   ·  ·  ·  ·  ·   ●●●●  ●●[pause]·······[resume]●●●
                          gap > 150s                paused window
              └─── run 1 ───┘            └────────── run 2 ──────────────┘
              └─ interval ─┘             └─ interval ─┘      └─interval─┘
```

Two signals because [§B.3](#b3--the-two-ways-of-not-watching) proved they are opposites. Intervals
rather than per-minute rows because per-minute explosion is the collapse mode the problem statement
names by hand.

**② `cc_minute_delta` — the serving layer.** `+1` when an interval opens, `−1` when it closes,
**clipped at every hour boundary** ([ADR 0003](adr/0003-hour-clipped-interval-splitting.md)):

```
 an interval running 20:59 → 22:04

   UNCLIPPED   +1 @20:59 ..................... −1 @22:05
               to read 21:30 you must sum from t=0. Partition pruning is useless.

   CLIPPED     hour 20 │ +1 @20:59   (survives the hour — no close emitted)
               hour 21 │ +1 @21:00   (fresh open)
               hour 22 │ +1 @22:00 … −1 @22:05
               ↑ every hour is now ABSOLUTE and standalone
```

Two payoffs: no query scans from the beginning of time, and peak becomes summable *across time*, so a
day-grain peak reads 24 stored rows instead of 1,440 minutes.

**③ `cc_hour_agg` — an 8-level cube, because peak does not add up.**

```
 true peak, all platforms      2,887
 sum of per-platform peaks     2,945   (+2.0%)
 sum of per-content peaks      4,433   (+53.6%)
```

Each of the 8 dimension subsets gets its own separately-computed curve and a genuine peak. Nothing is
derived from anything else.

**④ Both mandated models, side by side.** `cc_minute_delta` (session-aware) reads **2,887** at the peak
minute; `cc_minute_stateless` (session-independent) reads **2,894**. The gap *is* the excluded
background and paused time — the comparison is structural, not bolted on.

## C.3 · Does it handle what §B found?

| §B finding | Handled? | By what |
|---|---|---|
| Pause looks different from background | ✅ | the hybrid rule — the core design |
| Background/foreground do not pair | ✅ | we never pair them; gaps are primary |
| 4,210 duplicate rows | ✅ | **proven inert**, not patched — `evidence/dedup.txt` |
| Negative `content_id` | ✅ | `Int64` end to end + complex-key dictionary |
| Zero orphans today | ✅ | `LEFT` semantics + `'(unknown)'` default for the unseen day |
| Open sessions | ✅ | `is_open` + the truncation harness manufactures the case |
| Late arrivals | 🟡 | ADR 0006 arithmetic exact — only inside the isolated test |
| Peak not summable | ✅ | the 8-level cube, measured not asserted |
| 23.67% same-millisecond ties | 🟡 | `90_reconcile.sql` has a `DISTINCT` fix; the model has no explicit tie-break |
| **40-second cadence** | ❌ | `TAIL_S = 60` still assumes a cadence that does not exist |
| **`resume` overloaded (9.7%)** | ❌ | still closes at the first resume |
| **Un-normalised dimensions** | ❌ | ADR 0008 shipped them raw |
| **Title collisions** | ❌ | `v_concurrency_minute_title` merges distinct assets |

## C.4 · Accuracy has three different answers

**Level 1 — is the arithmetic self-consistent? Exactly yes.**

```
 delta layer  vs  interval expansion    3,725 minutes   0 mismatches
 hour tier    vs  minute tier              98 hours     0 mismatches
 incremental  vs  full rebuild          1,578 minutes   0 mismatches
 window views vs  brute-force join       every window   0 mismatches
```

**Level 2 — does the gate prove that? No, and this is the emergency.**

`sql/90_reconcile.sql` hard-codes five `2026-07-26` timestamps. Run against any other day it returns
**zero rows**, and `tools/reconcile.sh` decides the verdict with `grep -q MISMATCH`:

```
 zero rows  →  no MISMATCH string  →  exit 0  →  "reconcile PASSED"
 minutes actually compared: 0.      verdict printed: PASS.
```

It is blind a second way: the gate joins truth to served, and a minute where nobody was watching emits
no truth row, so it is never compared. Injecting **500 fabricated viewers** onto an idle minute in an
isolated database produced `PASS` from the committed shape and `MISMATCH` from the spine-driven shape.
207 of 1,364 minutes on 2026-07-25 are such minutes. Evidence: `evidence/unseen-rehearsal.txt`.

The hardened spine-driven form works but lives only in `tools/unseen-run.sh`; it has not been promoted
into the file `make reconcile` runs.

**Level 3 — do we match the private answer key? Unknown, with a measured envelope.**

```
                                    1,949.3 h  ← what we report today
     resume semantics (doubts/02)   −189.2 h   9.7%    MEASURED
     unclosed pause  (ADR 0007)     + 99.3 h   5.09%   MEASURED
     TAIL_S 60 vs 40 (doubts/01)    ≤ 170.9 h  8.8%    UPPER BOUND
```

These are **definitional forks**, not bugs — and the gate cannot see any of them, because it recomputes
truth using the same definition it is testing. A 9.7% error passes every test we own, silently.

A fourth, from the same adversarial pass: a **day-file answers differently from a full-context build**
(7 sessions straddle midnight on 2026-07-26; 1,140 events would be dropped by a same-shaped cut), and
both builds' gates say PASS because each recomputes truth from its own `ev_raw`. *The gate proves the
pipeline, never the input.*

## C.5 · What is broken, ranked

| # | Fault | Why it matters |
|---|---|---|
| 1 | **Gate passes vacuously off-day** | zero-minute PASS on the graded input |
| 2 | **Gate blind to idle minutes** | fabricated 500 → PASS |
| 3 | **`interval-math` skill teaches the discarded model** | *"Emitted every 60s"*, no pause — agents write SQL from it |
| 4 | **ADR 0008 shipped un-normalised dimensions** | `WHERE audio_language='hin'` misses 13% of Hindi |
| 5 | `DATA_DICTIONARY` — *"periodic, every 60s"*, *"≈78 min average session"* | both disproven in §B |
| 6 | `MENTOR_QUESTIONS` calls unclosed-pause the largest unresolved number | `resume` is ~2× bigger |
| 7 | `TESTS.md` still says absorption **"FAIL as shipped"** | fixed at `388a845`; evidence reads `CONVERGES` |
| 8 | `TAIL_S = 60` contradicts its own justification | the cadence exists and is 40 s |
| 9 | `45_user_concurrency.sql` stale comments | `ReplacingMergeTree(interval_end)`; "297 sessions" (301) |
| 10 | Peak minute ambiguous under ties | hour tier said 16:35, answer phase said 16:59 |
| 11 | `v_concurrency_minute_title` merges distinct assets | 2,773 colliding titles |

## C.6 · What is not built

```
 ❌ CONTINUOUS PUBLISHING   the biggest scored gap. We batch-rebuild with `make model`.
                            Only mv_stateless and mv_user_minute are real MVs.
 ❌ HOT TIER                BLOCKED, not unbuilt — ADR 0005 needs an operator decision.
 🟡 STRAGGLER PATH          arithmetic proven; not wired into a live path.
 ❌ /bench                  evidence/bench.txt and evidence/benchmark/ both MISSING.
 ❌ DECK · VIDEO · SUMMARY  none started.        ✅ LICENSE   ✅ README
 ❌ TEAM CAPTAIN            unnamed. Only they can submit.
```

**C in one sentence:** the model is arithmetically exact and the design is defensible, but the gate
that proves it **passes on zero rows** the moment the date changes, and three unanswered definitional
questions put a **±10% envelope** around the headline number that no test we own can detect.

# D · Why this approach, and what we rejected

## D.1 · The five forks

**Fork 1 · "How do we know someone stopped watching?"** Pairing `AppBackgrounded → AppForegrounded`
was rejected: 14,700 vs 14,321 → 379 never pair, and the organiser's own doc calls them "not
guaranteed." Heartbeat gaps were chosen ([ADR 0001](adr/0001-heartbeat-gaps-over-background-events.md))
— then immediately amended, because gaps catch backgrounding (silence) but **never** fire on a pause
(0.756 pings/min slips under any threshold). The answer is a **hybrid**, and it only exists because we
measured before building. A gap-only model would have shipped, passed every test, and been ~10% wrong.

**Fork 2 · "How do we store who was watching when?"**

```
 A  one row per (session, active minute)        ~185,000,000 rows   ✗
 B  an interval array per session               awkward to query    ✗
 C  +1 when a stretch opens, −1 when it closes       ~28,000 rows   ✓
```

**Fork 3 · "Does the running total carry across hours?"** Unclipped means every query scans from `t=0`
and partition pruning becomes decorative; snapshot checkpoints mean more state to get wrong.
Hour-clipping makes the carry-in problem *disappear* rather than be managed, and makes peak summable
across time ([ADR 0003](adr/0003-hour-clipped-interval-splitting.md)).

**Fork 4 · "What physical order for the raw events?"** This overturned our own earlier decision
([ADR 0002](adr/0002-order-by-time-bucket-then-platform.md)):

```
                              session-first   hour-first     hour-first is
   one-hour time slice        849,888 rows      434,176      2.0× better
   hour + platform filter     849,888 rows       49,152     17.3× better
   full interval rebuild      905,558 rows      905,558      IDENTICAL
```

The locality argument was wrong because our rebuild touches *all* sessions — it scans everything either
way, so ordering is irrelevant to it, while every dashboard query filters by time and often platform.

**Fork 5 · "What happens when data arrives late?"** `ALTER … UPDATE` is a heavy async mutation with no
read-your-writes; rebuilding the partition is literally the "recompute" answer the scoring criterion
penalises. Correction-by-diff ([ADR 0006](adr/0006-late-arrival-correction-by-diff.md)) recomputes one
session and appends the negation of its old deltas — *exactly as correct as a full rebuild, because it
is a rebuild, of one session.*

## D.2 · Measured, then rejected

**The projection — killed by its own measurement.** ADR 0002 named the remedy for the access pattern it
gave up: add a `PROJECTION` by `video_session_id`. We built it and measured **27.7×** on a
single-session lookup. Then we measured the *actual* access path — the straggler query uses
`IN (subquery)`, which full-scans anyway. Real gain **1.00×** for **+94% storage**. Kept in the tree,
documented, **not in the build path**. We rejected a recommendation our own ADR had made.

**Dedup — proven unnecessary rather than bolted on.** The full derivation was run twice in one query,
raw vs `LIMIT 1 BY` the event key, with `any()` pinned to `min()` so dedup was the only variable:
identical 30,769 intervals, **0 of 3,725 minutes differ**; restricted to only the 863 duplicate-bearing
sessions so it could not wash out, 834 minutes, 0 differing. *"We proved the step unnecessary" is a
stronger answer than "we added the step."* (`evidence/dedup.txt`)

**Three more, each with a number:** the gap-only model (heartbeats survive a pause at 0.756/min);
`uniq` HyperLogLog (1–2% error against an *exact* private key); `SummingMergeTree` over a distinct
count (measured **9×** over-count, 45,000 vs a truth of 5,000).

## D.3 · Small choices that would have broken silently

| Choice | What the obvious alternative does |
|---|---|
| `Int64` for `content_id` | `UInt64` dies at row 1193 on the planted `-987654322` |
| `COMPLEX_KEY_HASHED` dictionary | plain `HASHED` keys on `UInt64` *regardless of declared type* → `Code: 70` |
| `SimpleAggregateFunction(sum, Int64)` | `UInt64` **wraps** a negative correction; `sum()` stays right by modular arithmetic **so the bug hides**, `max()` returns 1.8e19 |
| `ReplacingMergeTree(build_version)` | `(interval_end)` keeps the largest end — but re-derivation can **shrink** an interval, so a stale row wins forever |
| `RANGE` window frames | `ROWS` — the delta layer stores only *change* rows, so "5 rows back" is not "5 minutes back" |
| `min_bytes_for_wide_part = 0` | compact parts report per-column compression as **0** — an evidence slide of zeros |
| load over **stdin** | `file()` cannot read a bind mount *and does not exist on Cloud*, the graded target |

## D.4 · The one thing deliberately not built

The **hot tier** ([ADR 0005](adr/0005-heartbeat-lease-semantics.md)). Each heartbeat grants a 150 s
lease; concurrency is the count of live leases. Provably equivalent to the gap model in the interior —
**and the gap model is exactly what ADR 0007 discarded.** *Equivalence to a discarded model is not a
correctness argument.* Exposure: 21,068 pause windows covering 834 h against 1,949 h of counted watch
time — the same order of magnitude as the answer.

Three ways out: pause-terminated leases need the cross-block state ADR 0004 exists to avoid; negative
lease rows are impossible because `uniqExact` has no subtraction; **relabelling it honestly as the
session-independent upper bound is free** — and is one of the two models the spec mandates comparing
anyway. That is the call awaiting a human.

## D.5 · The pattern

```
 sort key        settled by  17.3× / 2.0× / identical
 gap vs hybrid   settled by  0.047 vs 0.756 vs 4.72 pings/min
 version column  settled by  316 intervals, +37 on the peak
 the projection  settled by  27.7× benchmark → 1.00× reality
 dedup           settled by  0 of 3,725 minutes
 hot tier        settled by  834 hours of exposure
```

Not one was settled by argument, and four times the measurement overturned the plan — twice
overturning *our own* prior decision. The defensible story is not "we designed it well" but **"we kept
trying to disprove it, and here is the list of times we succeeded."** Which is also why §C stings: the
same discipline applied to the *gate* found it passing on zero rows.

# E · What is proven, what is only claimed, and what is missing

## E.1 · Proven — run, evidenced, reproducible

| Claim | The number | Evidence |
|---|---|---|
| Load is exact | 905,558 events = source rows · 33,464 titles | re-confirmed by the fresh reload |
| Serving layer == interval expansion | **3,725 minutes, 0 mismatches**, peak 2,887 | `tools/build-model.sh` |
| Hour tier == minute tier | **98 hours, 0 mismatches** | `sql/50_hour_agg.sql` |
| The 8-level cube | 26,162 rows, **0 peak + 0 integral mismatches** | `sql/50_hour_agg.sql` |
| Incremental absorption converges | **1,578 minutes, 0 mismatches** after the version fix | `evidence/truncation.txt` |
| Dedup is inert | 0 of 3,725 min; **0 of 834** on duplicate-bearing sessions alone | `evidence/dedup.txt` |
| Window views | rolling + tumbling vs brute force, **0 mismatches** | commit `4a89399` |
| Peak is not summable | +2.0% (platform), **+53.6%** (content) | measured |
| Sort key choice | **17.3×** on the dashboard shape | [ADR 0002](adr/0002-order-by-time-bucket-then-platform.md) |
| Serving beats expansion | 299 KB / 23 ms vs 2.55 MB / 56 ms — **8.5×** | TODOS H3 |
| Two-signal asymmetry | **0.047 / 0.756 / 4.72** pings/min | [ADR 0007](adr/0007-gate-answers-pause-needs-explicit-handling.md) |
| Straggler tail | 239 sessions, max **2,081 s** late | ADR 0007 |
| Charts show real data | HyperDX 61 → **2,887** → 7, 28 ms | [CLICKSTACK.md](CLICKSTACK.md) |
| Runs on a *different* day | **47 s** for 30,097 events, all 8 phases | `evidence/unseen-rehearsal.txt` |
| The gate *can* fail | bad delta row → exit 1 · fabricated 500 → MISMATCH | two negative tests |
| The 40-second cadence | p50 = p90 = **40.0 s** on three streams | §B.1 · [doubts/01](../doubts/01-heartbeat-cadence.md) |
| `resume` overload | **189.2 h · 9.7%** | §B.4 · [doubts/02](../doubts/02-resume-semantics.md) |
| Same-second tie bug | **41.5 h · 2.1%**, 2,697 pauses affected | §E.2 below |

## E.2 · Claimed, but not proven

```
 "our answers match the ground truth"
     ✗  UNPROVABLE without the key. Envelope ±10% across three definitional
        forks, none of which any test we own can detect.

 "make reconcile proves we are correct"
     ✗  PROVEN FALSE — zero rows → PASS on any day but 2026-07-26.

 "the model absorbs late data incrementally"
     🟡 TRUE in an isolated database. No live path: no finalizer, no watermark
        advance, no trigger. `make model` rebuilds.

 "dashboard-grade latency from a serving layer"
     ✗  NO /bench. evidence/bench.txt and evidence/benchmark/ do not exist.

 "designed for petabyte scale"
     ✗  ZERO measurements above 1×. Only timing: 47 s / 30K events.

 "filter-friendly across business dimensions"
     ✗  hin / HIN / hin-hindi / hin-Hindi are four buckets.

 "content-level concurrency by title"
     ✗  2,773 titles merge 2–4 content_ids, 1,418 across categories.
```

**A newly measured defect belonging here.** `sql/30_build_intervals.sql` truncates to whole seconds
(`toUnixTimestamp`) and then closes a pause with a strict `arrayFirst(x -> x > p, resumes)`. A resume
landing in that same truncated second is therefore **invisible**, and the pause runs on to the next
resume — or becomes unclosed and eats the rest of the run.

```
 pauses with a resume in the same truncated second   2,697   (9.86%)
 paused time excluded, shipped   (strict >)          834.1 h
 paused time excluded, inclusive (>=)                792.6 h
                                                     ───────
 over-excluded by the tie                             41.5 h   2.1%
```

`sql/90_reconcile.sql` contains the **identical expression**, so the gate reproduces the bug and agrees
with it — an independent *implementation*, but not an independent *definition*. Note the direction: it
pushes the opposite way to the `resume`-overload bug, so the two partially mask each other.

## E.3 · Knowingly missing

```
 ❌ CONTINUOUS PUBLISHING   spec step 4 · the biggest scored gap · we batch-rebuild
 ❌ HOT TIER                blocked on one human decision (ADR 0005 option 3 is free)
 ❌ /bench                  the cheapest unclaimed evidence in the project
 ❌ DECK · VIDEO · SUMMARY  none started          ✅ LICENSE  ✅ README
 ❌ TEAM CAPTAIN            unnamed — and only they can submit
```

Three more improvements not tracked elsewhere: **`session_start_epoch` is never used** by the model,
though it is the only exactly-reliable start signal (0 ms deviation across all 10,866 sessions) and is
precisely what a session truncated at the window edge needs; **no scale evidence exists above 1×**; and
`cc_minute_stateless` remains at **3 dimensions** while `cc_minute_delta` now carries **7**, so the
mandated session-aware vs session-independent comparison can only run at the coarser grain.

## E.4 · What we can honestly say today

> *"We built a foreground-only concurrency model on ClickHouse that excludes backgrounded and paused
> time. We proved the exclusion matters — 34.5% of apparent watch time, and a 22.1% over-count
> eliminated at the peak minute. The serving layer is an hour-clipped delta table, 6,600× smaller than
> per-minute explosion, and it reconciles exactly against raw events on every one of 3,725 minutes.
> Every design decision was settled by a measurement, and four overturned our own prior plan. We know
> of three definitional questions we cannot resolve without the answer key, we have measured what each
> is worth, and we can show the envelope."*

Every sentence there is backed. What we **cannot** say is "it is fast" (unmeasured), "it scales"
(unmeasured), or "our gate proves it" (it does not, off-day).

## E.5 · Highest grade-change per hour

```
 1  FIX THE GATE          ~30 min  without it nothing else we claim is backed.
                                   The working form already exists in
                                   tools/unseen-run.sh — promote it into
                                   sql/90_reconcile.sql and assert rows > 0.
 2  RUN /bench            ~45 min  the only scored criterion with zero evidence.
 3  TIE BUG + resume call ~1 h     41.5 h, and up to 189.2 h, of the answer.
 4  NORMALISE DIMENSIONS  ~30 min  or state the limit out loud.
 5  DECK                  starts at H18 regardless of code state.
```
