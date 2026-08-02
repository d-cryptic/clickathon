# 07 · Tail grace is paid after explicit stops — 60 s of watching credited past `VideoSessionEnd`

> **Summary:** The model credits `TAIL_S = 60 s` after the last event of every run, on the principle
> "we don't know when the viewer left." But **10,758 of 14,954 runs (72%) end at a `VideoSessionEnd`**
> — where we know to the second that they left — and **2,898 end at a `pause`**, where the model's own
> stated rule ("a segment ending at a PAUSE gets none") says no credit, yet pays it anyway because a
> trailing pause is filtered out of the pause list (`p < run_end`). Suppressing tail at both explicit
> stops moves the headline **2,917 → 2,776 (−141, −4.8%) and 1,978.1 → 1,837.2 h (−7.1%)**. The gate
> shares the convention and stays green either way. Deepens mentor **Q7** (tail grace), which carried
> no number; the trailing-pause half is arguably a plain inconsistency, not a fork.

**Status:** open · **Evidence measured:** 2026-08-01, local scratch `adv_q19` rebuilt verbatim from
`sql/30_build_intervals.sql` (baseline reproduces the graded 2,917 / 1,978.1 h exactly)

---

## The evidence

### 1 · Most runs end at an explicit stop, not in silence

```sql
WITH runs AS (
  SELECT video_session_id,
         arrayJoin(arraySplit((t, i) -> (i > 1) AND ((t - ts[i-1]) > 150), ts, arrayEnumerate(ts))) AS run,
         end_ts, ps
  FROM (
    SELECT video_session_id,
           arraySort(groupArray(toUnixTimestamp(event_timestamp))) AS ts,
           arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event_type = 'VideoSessionEnd')) AS end_ts,
           arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event = 'pause')) AS ps
    FROM ev_raw GROUP BY video_session_id))
SELECT count(),
       countIf(has(end_ts, run[length(run)])),
       countIf(has(ps,     run[length(run)]))
FROM runs;
```

```
 runs                              14,954
 …ending at a VideoSessionEnd      10,758   (72%)
 …ending at a pause event           2,898   (19%)
```

The tail-grace rationale — "the viewer was watching until at least the next expected beat" — applies
to a run that ends in **silence**. It does not apply to a run whose final event is the viewer
pressing stop, and the model already accepts this logic for pause: `30_build_intervals.sql` says
verbatim *"A segment ending at a PAUSE gets none: we know to the second when they stopped watching."*

### 2 · The trailing-pause half is the model contradicting itself

The no-tail-after-pause rule only fires when the pause is **strictly inside** the run: the pause
filter is `p >= run[1] AND p < run[length(run)]`, so a pause that is the run's **last event** is
dropped from the pause list, produces no window, the segment ends at `run_end` — and collects 60 s of
tail. That is exactly the viewer the rule was written for (pause, then the app goes silent — compare
the worked example in the file: paused 11:04:29, backgrounded 11:04:31). 2,898 runs hit it.

### 3 · The deltas, measured end to end (each variant = baseline + one edit)

Tail suppressed via `if(seg.2 = run_end AND NOT has(end_ts, toUInt32(run_end))
AND NOT has(pauses, toUInt32(run_end)), TAIL_S, 0)` — dropping either `has()` isolates one cause.

```
                                    peak              hours
 baseline (shipped)                 2,917             1,978.1
 no tail after VideoSessionEnd      2,804  (−113)     1,853.9  (−124.2 h, −6.3%)
 no tail after trailing pause       2,858  ( −59)     1,932.0  ( −46.1 h, −2.3%)
 no tail after either               2,776  (−141)     1,837.2  (−140.9 h, −7.1%)
```

All at the same peak minute, 2026-07-26 10:56. The gate (`90_reconcile.sql`) computes tail with the
identical rule, so it is green under the shipped reading and would be green under any of these.

### 4 · The tail length itself is the same lever (mentor Q7 / doubts/01)

`TAIL_S = 60` is commented "one cadence", but the measured cadence is **40 s**
([doubts/01](01-heartbeat-cadence.md)) — 60 is 1.5 cadences. Sweep, same harness:

```
 TAIL_S      0       40       60 (ship)   80       120
 peak        2,758   2,872    2,917       2,968    3,047
 hours       1,828.5 1,928.2  1,978.1     2,028.0  2,127.7
```

Slope ≈ **2.4 peak viewers and 2.5 h per tail-second**. Taking the file's own justification at its
word (one cadence = 40 s) is worth −45 viewers (−1.5%) on its own.

## Exactly what to ask

> "When a viewing burst ends with an explicit `VideoSessionEnd`, should the model still credit a
> grace period past it (we currently add 60 s), or does watching end at the event? Same question for
> a burst whose last event is a `pause`. And is 60 s the right grace for a burst that ends in
> silence, given the measured 40 s heartbeat cadence? These choices are jointly worth 141 viewers
> (4.8%) of our peak and 7.1% of counted hours."

## Why this is worth mentor time

Only partially — the **trailing-pause half (−59 / −2.0%) is an internal inconsistency** we can
defend fixing without a ruling: the model's own comment states the principle, and the code misses
one case of it. The **`VideoSessionEnd` half (−113 / −3.9%)** is a genuine convention: an answer key
built from the same telemetry may well credit nothing after an explicit end, and a key built from
"lease" semantics may credit a cadence. Under exact raw-event spot-checks, 141 viewers is far
outside plausible noise.

## How the answer changes what we build

| Answer | Change |
|---|---|
| Grace after silence only; none after explicit stops | Add `end_ts` to `per_session`, carry it (and `pauses`) into the tail condition in `30_build_intervals.sql`; mirror in `90_reconcile.sql`; rerun `/reconcile`. Peak 2,776. |
| Grace after silence and pause-tail fixed, end-event keeps grace | Same edit, `has(pauses, …)` only. Peak 2,858. |
| Keep grace everywhere (our assumption) | Nothing — but record the ruling in ADR 0007, because the in-file pause principle then needs rewording. |
| Grace = one cadence (40 s) | `TAIL_S` 60 → 40 in both files. Peak −45 on top of whichever row above. |

## Our current assumption

Tail after every run end, 60 s, including runs ending at explicit stops. Shipped in model and gate.

## Answer

_unrecorded_
