# 01 · The heartbeat ticks at 40 seconds. Your spec says 60.

> **Summary:** `dataset_details.md` states the heartbeat "is currently passed every 1 minute." Measured
> on the delivered file, the periodic telemetry streams tick at **exactly 40 seconds**, not 60. Our
> earlier reading — recorded in ADR 0007 and Q17 as "there is no cadence, it is bursty noise" — was an
> artefact of measuring all 41 `VideoHeartbeat` sub-events **mixed together**; separated, three of them
> are metronomes. Both of our activity tunables (`GAP_S = 150`, `TAIL_S = 60`) are functions of a
> cadence, so if judge spot-checks assume 60 s, every interval boundary we produce is offset.
> **Supersedes Q17 in [docs/MENTOR_QUESTIONS.md](../docs/MENTOR_QUESTIONS.md).**

**Status:** open · **Evidence measured:** 2026-08-01, local `csv_audit.raw_str`, fresh CSV load,
905,558 rows

---

## The evidence

### 1 · `VideoHeartbeat` is not one signal — it is 41

843,600 rows (93.16% of the file) share the event_type `VideoHeartbeat`. The `event` sub-column splits
them into 41 distinct streams. The cross-tabulation is strictly disjoint — every `event` value belongs
to exactly one `event_type`.

```sql
SELECT event, count() AS c
FROM csv_audit.raw_str
WHERE event_type = 'VideoHeartbeat'
GROUP BY event ORDER BY c DESC;
```

```
 network-activity  177,485     video_forward  49,879     upshift         19,400
 buffer-health     167,460     Seek           32,036     dropped-frames  11,089
 video-resize      141,250     resume         31,780     downshift        7,294
 BufferStart        66,641     network-bandwidth 30,637  video_rewind     6,587
 BufferEnd          66,289     pause          27,340     … 27 more, down to 1
```

### 2 · Mixed together they look aperiodic. That is what we measured before.

Inter-arrival between consecutive `VideoHeartbeat` rows within a session, `quantileExact`:

| p50 | p90 | p99 | p999 | max |
|---|---|---|---|---|
| **0.142 s** | 40.001 s | 48.8 s | 805 s | 142,542 s |

A p50 of ~0 is what produced the "bursty, no cadence" conclusion in ADR 0007.

### 3 · Separated, three of them are metronomes at exactly 40 seconds

Self-cadence of each stream measured independently:

| stream | rows | p50 gap | p90 gap |
|---|---|---|---|
| `network-activity` | 177,485 | **40.0 s** | **40.0 s** |
| `buffer-health` | 167,460 | **40.0 s** | **40.0 s** |
| `video-resize` | 141,250 | **40.0 s** | **40.0 s** |
| `network-bandwidth` | 30,637 | ~120 s | ~120 s |

Three independent clocks, all at 40 s, offset from one another. Summed, their gaps collapse toward
zero — which is exactly the p50 = 0.142 s above. The pulse was always there; we were measuring the sum
instead of the parts.

### 4 · The histogram confirms it — the mode is the 40-second bucket

Gap histogram over **all** consecutive within-session events:

```
   40 s  ████████████████████████████████  100,099 gaps   ← the mode
    1 s  █████████████                      40,910
   30 s  ████                               14,167
```

### 5 · What we currently ship, and the reasoning behind it

```
 sql/30_build_intervals.sql
   GAP_S  = 150   -- "~3x the measured inter-arrival p99 of 49s"  (ADR 0007)
   TAIL_S =  60   -- originally "one cadence"; Q17 downgraded it to
                  --   "an arbitrary constant, because no cadence exists"
```

Against a real 40 s pulse: `GAP_S = 150` is **3.75 missed beats** (not 3× a p99), and `TAIL_S = 60` is
**1.5 cadences**, not one.

---

## Exactly what to ask

> "Your dataset doc says the heartbeat is passed every one minute. We measured the file you shipped:
> `VideoHeartbeat` is actually forty-one different telemetry streams under one label, and the three
> big periodic ones — `network-activity`, `buffer-health`, `video-resize` — each tick at **exactly
> forty seconds**, p50 and p90 both 40.0. Mixed together they look like noise, which is what fooled us
> at first; separated, they're metronomes. `network-bandwidth` runs at 120 seconds.
>
> **Question one:** when judges decide whether a viewer was active, do they assume a
> sixty-second cadence — for example 'active for the 60 seconds after each heartbeat', or an inactivity
> timeout expressed as N missed 60-second beats — or was it derived from the forty-second pulse that is
> actually in the data?
>
> **Question two:** do *all* forty-one sub-events count as evidence of watching, or only a subset? We
> currently count all of them except explicitly paused windows.
>
> We're not asking you to reveal the answer key. We're asking which number our thresholds should be a
> multiple of, because right now we have a tail-credit constant of sixty seconds that was justified as
> 'one cadence' and the cadence turns out to be forty."

---

## Why this is worth mentor time

Every boundary of every active interval is a function of the cadence. This is not a tuning
preference — it is a definitional input we cannot recover from the data, because **both readings are
internally consistent**. The file ticks at 40 s; the spec says 60 s. If the generator emitted at 60 s
and the delivery pipeline resampled, we have tuned to an artefact. If the generator emitted at 40 s
and the doc is stale, our current `TAIL_S = 60` over-credits every interval by half a cadence.

It cannot be measured our way out of: the judge interpretation is unspecified, so a wrong guess is silently wrong
on **every** benchmark answer and on the unseen day, and nothing looks broken.

## How the answer changes what we build

| If they say | We change | Cost |
|---|---|---|
| **"60 s is authoritative"** — the key assumed a 1-minute beat | keep `TAIL_S = 60`; re-derive `GAP_S` as 3 missed 60 s beats → **180**; re-run `/reconcile` | two constants + one rebuild (~11 s) |
| **"the shipped data is authoritative"** — 40 s is real | `TAIL_S` → **40** (one true cadence); `GAP_S` → **120** (3 × 40); re-run `/reconcile` and the tail-sensitivity sweep | two constants + one rebuild |
| **"we don't model cadence at all"** — active = any event within a fixed window | drop the cadence justification entirely; ask for the window; `GAP_S` becomes that number | one constant, and ADR 0007's reasoning is rewritten |
| **"only a subset of the 41 sub-events count"** | add an event allow-list to the `per_session` CTE in `sql/30_build_intervals.sql`; every interval shortens | one `WHERE`, full rebuild + reconcile |
| *no answer received* | ship `TAIL_S = 60`, `GAP_S = 150`, and **state the 40 s finding out loud in the deck** — "we found the pulse, we chose the conservative constant, here is the sensitivity" | zero; turns an unknown into a defended trade-off |

Whatever the answer, the **tail-sensitivity sweep** (`GAP_S` × `TAIL_S` grid, TODOS H8) becomes the
insurance policy: it shows how much the headline number moves across the plausible range, so a wrong
guess is bounded rather than invisible.

## Our current assumption

The shipped data is authoritative. Thresholds derived from the measured distribution, not the doc.
`GAP_S = 150`, `TAIL_S = 60` — **and `TAIL_S` is now known to be inconsistent with its own
justification.**

## Answer

_unrecorded_
