# demo/replay.sh — the replay demo, and exactly what it proves

> **Summary:** Replays a live-event day into a **scratch** database in event-time order, compressed
> 60×, with `tools/publish.sh` running against it, so the concurrency curve **builds while you
> watch** — the one thing `demo/run.sh` cannot show. Four beats: the curve building, a
> platform/country filter answering mid-replay, a **late arrival correcting already-published
> history in place**, and the committed reconcile gate passing at the end. Rehearsed end to end:
> 905,558 events in 168 s, 29 incremental publish runs, **zero rebuilds**, gate green on 17,028
> minutes at peak 2,917. **It says nothing about the graded service:** `sonyliv` is batch-rebuilt,
> its publisher has committed **zero** runs, and its cursor is at epoch. Read "What is real and what
> is staged" before presenting.
> Transcript: [`evidence/demo-replay/rehearsal.txt`](../evidence/demo-replay/rehearsal.txt).

## Why this exists

`docs/upstream/PROBLEM_STATEMENT.md`, "Suggested demo":

> *"Replay a live-event day: ingest the session stream → **the concurrency curve builds in near real
> time** as sessions open, heartbeat, and close → apply a filter (platform, country) and the
> minute-grain view answers instantly."*

`demo/run.sh` is the rehearsed five-minute demo and it is honest, timed and read-only — but it
queries a model that was **already built**. It never shows the curve building. This script does.

It also makes a separately-scored capability visible for the first time. The statement asks how the
serving layer absorbs updates — *"incrementally, or by recomputing?"* — and we have a genuine
incremental publisher ([ADR 0013](../docs/adr/0013-continuous-publication-by-incremental-finalizer.md),
[ADR 0016](../docs/adr/0016-publisher-owns-the-user-and-hour-tiers.md)) proven byte-identical to a
rebuild across four tiers in [`evidence/publish.txt`](../evidence/publish.txt). Until now that proof
was a table of zeros in a file. The replay is the same claim, watchable.

`demo/run.sh` is unchanged and still works exactly as rehearsed. This is a **second** demo, not a
replacement.

## Run it

```bash
demo/replay.sh                  # setup + replay, ~4 min total (~2.5 min of replay)
demo/replay.sh --capture        # ...and tee the transcript to evidence/demo-replay/
demo/replay.sh --resume         # skip setup, replay into the existing scratch db
demo/replay.sh --setup-only     # build the scratch db and stop
demo/replay.sh --speed 120      # 2x faster (event-seconds per wall-clock second)
demo/replay.sh --target cloud   # against a Cloud scratch db (slower; see below)
```

Default target is **local** (the `ch` container). That is deliberate: a publish run costs ~4 s
locally against ~15–20 s on Cloud, most of it `SYSTEM FLUSH LOGS` per phase
([ADR 0023](../docs/adr/0023-publish-visibility-contract-and-one-block-correction.md) §3), and at
Cloud latency the curve steps forward too rarely to read as live. Local also keeps the graded
service entirely out of the loop.

## What you are watching

```
09:41→09:28  │▇▇▇▆▆▅▅▅▆▆▇█▇▆·····················│ cc 43  pk 43  lag 10s  q 50
└─ replay clock                                     └─ concurrency at the absorbed edge
      └─ absorbed through (the gap IS the publish lag)      └─ peak so far
                                                                    └─ queue depth
```

- **Two clocks.** The replay clock is where the stream is; *absorbed-through* is the newest event
  time the publisher has fully digested. The gap between them is real freshness, shown rather than
  smoothed away.
- **`~`** marks a sample that landed mid-publish. It is **not charted** — see below.
- **The curve is log-scaled**, with both ends of the axis anchored to what is on screen. This day
  spans ~30× between the pre-event ramp (~30 concurrent) and the peak (2,917); on a linear axis the
  entire ramp collapses to one glyph the moment the peak lands, which defeats the point. `cc` and
  `pk` are printed as numbers so nothing rests on the glyph heights.

### The four beats

1. **The curve builds.** Ticks insert every event in `(last, now]` in event-time order.
   `tools/publish.sh --loop 1` runs against the same database throughout. **The curve moves only
   because the finalizer ran** — `tools/build-model.sh` is never invoked and no `TRUNCATE` is
   issued.
2. **The filter answers mid-replay.** Platform and country breakdowns off `cc_minute_delta`, timed,
   while the stream is still landing.
3. **A late arrival corrects history.** 37 sessions are withheld from the stream entirely and
   injected ~25 event-minutes late. A minute that already scrolled past visibly corrects itself.
4. **The gate.** `sql/90_reconcile.sql` — the committed gate, unmodified — recomputes truth from
   `ev_raw` with a different algorithm and compares every minute.

## Measured in the committed rehearsal

Everything below is from [`evidence/demo-replay/rehearsal.txt`](../evidence/demo-replay/rehearsal.txt),
one uninterrupted run on the local container. Numbers, not adjectives.

| | |
|---|---|
| ingested | **905,558 events** in 39 ticks over **168 s** (9,060 s of event time at 60×) |
| publisher | **29 committed runs**, 36,025 session-derivations, **0 rebuilds, 0 `TRUNCATE`s** |
| serving layer | 41,788 delta rows · 30,323 intervals |
| peak served | **2,917** at 10:56 — the correct peak for this day |
| publish lag | median **11 s**, max **29 s** wall clock across 44 frames (this is a 60× stress figure) |
| queue depth | peaks at **5,140** sessions during the 10:30–11:00 burst, drains to 0 |
| filter latency | **386 ms** (platform) and **328 ms** (country) *while the publisher was running*; the same queries measured **32–73 ms** on an idle database. Contention with a concurrent publish is the difference — quote the honest number, and use `/bench` for rigorous latency work |
| late arrival | minute 09:58: **35 → 51 (+16)**, corrected in place |
| ADR 0023 dip | 44 samples, **18 landed mid-publish**, 2 more caught by the drop guard; deepest suppressed sample **−58% (1,909 → 796)** |
| gate | **17,028 minutes compared, 0 mismatched, max_abs_diff 0** |
| total | 206 s wall clock including setup |

Two of these deserve emphasis. **18 of 44 samples landed mid-publish** — that is not a rare race, it
is 40% of reads, and it is why the gating below exists rather than being optional. And the gate
comparing **17,028 minutes with zero mismatches** is the whole argument: the curve was assembled by
29 incremental corrections and a late injection, and it landed in exactly the same place a
from-scratch rebuild would have.

## What is real and what is staged

**This is the section to read before presenting.**

| | |
|---|---|
| **Scratch, not graded** | Everything runs in a database this script creates and destroys (default `sonyliv_t7replay`). The script **refuses** to target `sonyliv` or `default`, and refuses to run at all if `PUBLISH_ALLOW_PROD=1`. |
| **The graded service does none of this** | `sonyliv` is **batch-rebuilt**. Its publisher has committed **zero** runs and its cursor is at epoch. Its `cc_user_minute` is still pre-ADR-0016 (`SharedAggregatingMergeTree`, `mv_user_minute` live), so running the publisher against it would write replace-semantics rows into a set-union table and silently inflate the user tier. **Nothing in this replay is running in the graded service, and it must not be.** |
| **Time is compressed 60×** | Sessions open, heartbeat and close in the right *order* and the right *relative* spacing, but 60× faster. Ingest is therefore ~60× the real rate. |
| **Publish lag here is a 60× stress figure** | Measured median 11 s, max 29 s wall clock, with the queue reaching 5,140 sessions during the 10:30–11:00 burst and the absorbed edge falling tens of event-minutes behind. That is what happens when you feed a publisher an hour of a national live event in one minute. It is **not** a production freshness number and must not be quoted as one — at 1× the same work arrives 60× slower. |
| **`PUBLISH_SETTLE_S=3`, not the default 5** | Settle is the floor on publish lag and the one assumption in the publisher's design (no insert takes longer than settle between `now64(3)` and its rows being visible). 3 s is safe for a single-writer local replay; it is a demo tuning, not a recommendation. |
| **History is preloaded** | Everything before 09:00 is bulk-loaded and published before the replay starts. A live-event day does not begin with an empty serving layer. The replay covers 09:00 → 11:31, which is the ramp, the peak (2,917 at 10:56) and the drain. |
| **The stream is staged, not re-parsed** | The CSV-loaded events are copied once into a `replay_source` table in the scratch database, so a tick is a server-side slice rather than 800k rows over the wire fifty times. Same rows, same lineage: local reads the container's CSV-loaded `ev_raw`; `--target cloud` reads graded `sonyliv.ev_raw` **read-only**. |
| **The late arrival is engineered** | The 37 withheld sessions are chosen by a deterministic *property* — every session that both opens and closes inside 09:30–10:20 — not hand-picked to flatter the result. Their lateness is simulated by withholding them; nothing in the source data was late. |

## The dip you will hit, and what the script does about it

[ADR 0023](../docs/adr/0023-publish-visibility-contract-and-one-block-correction.md) measured that a
reader polling during a publish can see the curve collapse by up to **−87.8% for 13.6 s**: between
the `negated` and `emitted` phases the serving table holds `-deltas(old)` with no `+deltas(new)`
yet. A live replay polls constantly, so **this will be hit on every run**. An unexplained collapsing
curve on stage is the worst possible outcome, so:

- Every read that becomes a number on screen — the chart sample, the late-arrival probe, the
  filter — is **bracketed by phase probes**. If the minute tier was mid-correction on either side of
  the read, the sample is marked `~`, the previous good value is carried, and the read is retried.
- What the suppressed sample *would* have shown is recorded and **reported in the closing summary**
  as a measured dip. We refuse to chart it and we refuse to hide it.
- A **drop guard** catches the residual race: phase markers are written *after* their statement
  returns, so `claimed` can briefly outlive a landed negation. A fall steeper than 40% off a base of
  at least 50 viewers while any run is in flight is treated as suspect.

**A finding this demo added to the ADR's account:** mid-dip, a *filtered* query does not merely read
low — every running sum in the window goes to zero, `HAVING concurrent > 0` keeps nothing, and the
filter returns an **empty table**. ADR 0023 documents the magnitude of the dip but not this failure
mode, which reads as a broken filter rather than as staleness. That is why the filter beat waits for
a safe window (and says so when it had to).

### The chart edge is held back on purpose

The right-hand edge is **not** `max(minute)` in `cc_minute_delta`. A batch's intervals all *close* at
the end of their coverage, so the newest published minute is opens-minus-closes ≈ 0 until later
batches publish the sessions still active there — charting it drops the curve off a cliff every
frame (measured once as `cc 3` on a curve sitting at ~35). The edge is instead derived from the
publisher's own bookkeeping — the newest event time among markings at or before the committed
cursor — then held back by one tick of event time plus two interval tails, and kept **monotonic** so
a straggler cannot rewind the chart. This is the same "leave the trailing window alone" rule as
`PUBLISH_SETTLE_S`, applied to reads. It is a margin, not a proof.

## Does it agree with the truth?

Every run ends by executing the committed gate, `sql/90_reconcile.sql`, unmodified, against the
scratch database. Truth is recomputed from `ev_raw` with a different implementation (window
functions, not `arraySplit`) and never reads the serving layer, so it tests the pipeline instead of
agreeing with itself. The rehearsal shows it passing over **17,028 minutes with zero mismatches and
`max_abs_diff` 0, at the correct peak of 2,917** — meaning the curve you watched being assembled
incrementally, including the retro-corrected minute, is identical to what a from-scratch rebuild
would have produced.

That is the whole argument for the incremental path, made watchable:

> **incrementally, or by recomputing?** — Incrementally. And here is the gate proving it landed in
> the same place.

## Files

| Path | What |
|---|---|
| `demo/replay.sh` | the script |
| `demo/REPLAY.md` | this file |
| `evidence/demo-replay/rehearsal.txt` | full captured transcript of a rehearsed run |
| `evidence/demo-replay/reconcile.txt` | the gate's own output from that run |

`demo/run.sh` and `demo/SCRIPT.md` are **untouched** — the rehearsed five-minute demo is committed
evidence and still runs exactly as before.
