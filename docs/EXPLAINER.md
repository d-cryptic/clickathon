# EXPLAINER — the whole problem in layman terms

> **Summary:** A from-scratch, plain-English walkthrough of what we were asked to build and why the
> obvious approach is wrong, written for someone who has never seen the repo — a new teammate, a judge,
> or the author at hour 18. Section A is the **ask**; B is **why it is hard**; C is **what we built**;
> D is **why this approach and what we rejected**; E is **proven vs. missing**. Every number here is
> measured against the graded ClickHouse Cloud service, never hand-computed. Where a number is
> load-bearing, the query that produced it is shown. Deeper treatments:
> [ARCHITECTURE.md](ARCHITECTURE.md) for the model, [adr/](adr/) for the decisions,
> [DATA_DICTIONARY.md](DATA_DICTIONARY.md) for the field-level detail.

**Status:** A written. B–E in progress.

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

# B · Why it is hard

_To be written._

# C · What we built

_To be written._

# D · Why this approach, and what we rejected

_To be written._

# E · Proven vs. missing

_To be written._
