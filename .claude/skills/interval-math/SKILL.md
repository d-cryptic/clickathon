---
name: interval-math
description: Correct active-interval reconstruction and concurrency arithmetic for the SonyLIV problem. Use when writing or reviewing any interval, delta or peak/average query.
---

# Interval and concurrency arithmetic

## The model is a HYBRID — gaps for backgrounding, explicit subtraction for pausing

```
ACTIVE = (a run of events with no gap > HEARTBEAT_GAP_S)  MINUS  (explicit pause windows)
```

Two signals, because the two ways of not-watching look nothing alike. Measured
([ADR 0007](../../../docs/adr/0007-gate-answers-pause-needs-explicit-handling.md), confirmed in
[EXPLAINER §B.3](../../../docs/EXPLAINER.md)):

| state | events/min | median window | detected by |
|---|---|---|---|
| **actively watching** | 4.72 | — | — |
| **backgrounded** | 0.047 (a 100× drop) | 35 s | a heartbeat **gap** — the app goes silent |
| **paused** | 0.756 ≈ one event every 79 s | 20 s | **nothing.** It slips under any sane gap threshold |

**A gap-only model silently counts paused time as watching**, which the problem statement forbids.
Pause must be subtracted from explicit `pause` / `resume` events; it can never be inferred from
silence. That correction is the core of the design, not a refinement — see
`sql/30_build_intervals.sql`.

## Deriving active intervals

Signals, in order of reliability:

1. **Heartbeat gaps → backgrounding only.** A gap > `HEARTBEAT_GAP_S` (shipped `GAP_S = 150 s`)
   closes the run. Do **not** expect the gap to catch a pause; measurement above says it will not.
2. **Explicit `pause` / `resume` → pause exclusion.** Clip the pause windows out of the run and emit
   the complement. Shipped rule: a pause closes at the **first `resume` after it**
   (`arrayFirst(x -> x > p, resumes)`); a pause with no later resume runs to the **end of the run**
   (`UNCLOSED_PAUSE_TO_RUN_END = 1`, conservative). Match `event = 'pause'` / `'resume'` **exactly** —
   a `LIKE '%pause%'` refactor also captures `AdPause`, `speed-pause`, `download_resumed` (836 rows,
   [doubts/02 §5](../../../doubts/02-resume-semantics.md)).
3. **`VideoSessionStart` / `VideoSessionEnd`** bound the session — but an end may be **absent**
   (open session), and 239 sessions emit 802 events *after* their own end. Never assume it exists,
   never assume it is final.
4. **`AppBackgrounded` / `AppForegrounded`** corroborate only. They are explicitly **not guaranteed**;
   measured 379 unmatched and 418 sessions that background and never return. Never pair them.

Give the final heartbeat of a run **one cadence** of credit (`TAIL_GRACE_S`, shipped `TAIL_S = 60`) —
not the whole gap, and **only where the run ends in silence**. A segment ending at an explicit `pause`
gets no tail credit; crediting it would book paused time as watched.

## The cadence is 40 seconds, not 60

The organiser's `dataset_details.md` says the heartbeat "is currently passed every 1 minute". The
shipped file does not. `VideoHeartbeat` is **41 telemetry sub-streams under one label**; measure them
mixed together and the p50 inter-arrival is 0.14 s ("no cadence" — the conclusion this skill used to
carry). Separated, three of them are metronomes:

```
 network-activity   177,485 events    p50 = p90 = 40.0 s
 buffer-health      167,460           p50 = p90 = 40.0 s
 video-resize       141,250           p50 = p90 = 40.0 s
 network-bandwidth   30,637           ~120 s

 gap histogram over ALL within-session events — the MODE is the 40 s bucket:
   40 s  ████████████████████████████████  100,099 gaps
    1 s  █████████████                      40,910
   30 s  ████                               14,167
```

So the shipped constants are **not** what their comments claim: `GAP_S = 150` is 3.75 missed beats,
and `TAIL_S = 60` is **1.5 cadences**, not "one cadence". Both are still what we ship; the
justification is what changed. Dossier and the question to ask a mentor:
[doubts/01](../../../doubts/01-heartbeat-cadence.md).

## Two definitional forks live in this arithmetic — do not "fix" them silently

Both are measured, both are unresolved, and `/reconcile` **cannot see either** (it recomputes truth
with the same rule it is testing, so it agrees with itself by construction):

| fork | shipped choice | what the other reading costs |
|---|---|---|
| **`resume` semantics** ([doubts/02](../../../doubts/02-resume-semantics.md)) | close a pause at the *first* resume | **189.2 h · 9.7%** of counted watch time. 9,958 back-to-back `resume→resume` runs prove `resume` fires for seeks and buffer recovery too |
| **unclosed pause** (`UNCLOSED_PAUSE_TO_RUN_END`, `cf80acc`) | conservative — paused to the end of the run | on hours, 99.3 h · 5.09%. **On the graded PEAK: 2,887 → 3,018, +131 viewers · +4.5%** |

Changing either means changing `sql/30_build_intervals.sql` **and** the independent re-implementation
in `sql/90_reconcile.sql`, then re-running `/reconcile`.

## Deltas, not explosion

Per-minute explosion is O(sessions × minutes) and collapses at scale (~185,000,000 rows here against
~28,000 in the delta layer). Emit `+1` at the minute an interval opens and `−1` at the minute after it
closes; concurrency is the running sum.

```sql
-- concurrency at each minute
SELECT minute, sum(sum(delta)) OVER (ORDER BY minute) AS cc
FROM cc_minute_delta GROUP BY minute ORDER BY minute
```

Merge a session's intervals that land on the **same minute** before emitting. Without that merge one
viewer contributes two `+1`s — the bug `/reconcile` already caught once (556 of 1,903 minutes wrong;
4,797 sessions, 44%, pause and resume inside one minute).

## The two arithmetic traps

1. **Peak is not summable and not decomposable.** platform+content may peak at a different minute
   than platform+country. Never store one peak; take `max()` of the running sum at query time, over
   the filtered combination. Measured: true peak 2,887 vs 2,945 summing per-platform peaks (+2.0%)
   and 4,433 summing per-content peaks (+53.6%).
2. **Never sum a distinct count across buckets.** A `SummingMergeTree` over `uniqExact` over-counts —
   measured **9×** (45,000 vs a truth of 5,000) on a comparable cascade. Use
   `AggregatingMergeTree` + `uniqState`/`uniqMerge`, and `-MergeState` for a second hop.

## Average concurrency

Time-weighted, not a mean of per-minute values, unless every bucket is the same width. At minute grain
they are equal; at hour/day grain over a partial range they are not. State which you used.
