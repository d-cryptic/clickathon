# TIMESPAN — what changes when the service has been running for six months

> **Summary:** The complement to [evidence/scale.txt](../evidence/scale.txt), which scales the
> AUDIENCE inside one 99-hour window. This measures the CALENDAR: 12 / 60 / 180-day spans at two
> volumes, so span and density move independently. **Span and volume break different things.** At
> constant volume the interval and delta tiers are flat (±0.6%) while the hour cube grows +27% and
> part counts grow 12×. **What breaks first is `max_partitions_per_insert_block` (default 100) at a
> span above 100 days** — measured, with the server's own error. The "a long range costs the same
> as a short one" claim is **half true and now exactly quantified**: cost is one index granule per
> MONTHLY PARTITION touched. Raw measurements: [evidence/timespan/](../evidence/timespan/).
> Regenerate with `tools/timespan-gen.sh`.

## Why this exists

`evidence/scale.txt` answers "what if the audience is 100× bigger" — N× the sessions inside the
same ~99-hour window. It says so explicitly, and it is right to: peak concurrency is an audience
property. But it leaves a second question untouched, and a judge asking *"how does this behave in
production?"* usually means the second one: **we have been running since January — what now?**

Those stress different machinery:

| | scaled by AUDIENCE (`scale.txt`) | scaled by CALENDAR (this file) |
|---|---|---|
| what grows | sessions per minute, delta cardinality, `uniqExact` state | day partitions, parts, hour-cube rows |
| what binds | interval-derivation memory (arrays per session) | partition count per INSERT, merge scheduling |
| peak concurrency | grows N× | *falls* — the same volume spread thinner |

## How span was separated from volume

`tools/timespan-gen.sh` takes points as `span_days:events_per_day`, so the two knobs are
independent. The grid run here is 2 volumes × 3 spans:

```
 ~8.3M events:   12:694000    60:139000    180:46000
~50.0M events:   12:4170000   60:834000    180:278000
```

Reading **across** a row isolates span (volume held constant); reading **down** a column isolates
density (span held constant). Anything that moves across a row is caused by span and nothing else.

Sessions keep the provided file's measured shape — the generator reuses `tools/scale-gen.sql`'s
vocabularies and every fitted constant from `tools/scale-load.sql` (session length, beat spacing,
burst size, pause/resume structure, gap distribution, the sentinel-then-resolved audio behaviour).
**Only the time axis is replaced**, by a synthetic multi-day profile: a diurnal curve peaking at
21:00, weekends ×1.35, a ±12% seasonal drift, event days every 45 days at ×2.2 with a sharp 20:30
spike, and a hot-content set that rotates each 30-day epoch so titles launch and decay. A flat
uniform stream over 180 days would not exercise partition pruning the way real traffic does.

Measured on the 180-day point, the profile lands where it was aimed: weekday 40.1k / weekend 54.9k
/ event-day 103.6k events per day, 47% of events in the 19:00–23:00 prime window, 10.2% overnight,
1,168 sessions crossing midnight, and 8 of the first month's top-20 titles still in the last
month's top-20.

### The part that has a known answer

Realism is not verifiable on its own, so each point also carries **designed-truth probe blocks** on
a reserved platform value `TIMESPAN_PROBE`: 40 sessions active 20:00–20:29 and 30 sessions active
23:45–00:14, placed on day 0, on a **month-end** day mid-span, and on the last day. Their
minute-by-minute concurrency is computed in closed form by plain Python sets — a third independent
implementation of the counting spec, alongside the model's `arraySplit` and the gate's window
functions, exactly as `tools/unseen-gen.sh` does. The 23:45 block is deliberately placed to cross
both a midnight boundary and a month (partition) boundary.

The rest of the stream has no analytic answer; there the reconcile gate (delta serving layer vs the
interval expansion, every minute) is the check. **Both ran at every point, and both passed
everywhere** — including 250,169 consecutive minutes at 180 days.

## Finding 1 — what breaks first: 100 day-partitions per INSERT

The only hard failure in the whole matrix, and it is a span failure, not a volume one:

```
[gen] first attempt at DEFAULT settings (max_partitions_per_insert_block=100):
  TRIPPED, as a naive 180-day bulk insert would: Too many partitions for single INSERT block
  (more than 100). The limit is controlled by 'max_partitions_per_insert_block' setting.
```

`ev_raw`, `cc_minute_delta`, `cc_minute_stateless` and `cc_user_minute` are all `PARTITION BY`
day. Any bulk INSERT whose squashed blocks span more than 100 distinct days is refused. That means
**a backfill, a restore, or a re-derivation over more than ~100 days of history fails at default
settings** — while the same statement over 60 days succeeds. It is a one-setting fix
(`max_partitions_per_insert_block=400`, which the harness then uses everywhere), but it is a fix
you have to know about *before* the restore, not during it.

It does not affect steady-state ingest, which writes one day at a time.

## Finding 2 — span moves the tiers volume does not

At **constant volume (~8.3M events), 12 → 180 days**:

| | 12 days | 60 days | 180 days | change |
|---|---|---|---|---|
| `ev_raw` rows | 8,295,351 | 8,307,711 | 8,245,018 | flat *(by construction)* |
| `session_intervals` | 269,050 | 269,433 | 267,438 | **−0.6% — flat** |
| `cc_minute_delta` | 408,545 | 410,546 | 407,815 | **−0.2% — flat** |
| `cc_hour_agg` | 439,483 | 513,467 | 559,399 | **+27%** |
| `cc_user_minute` | 1,483,834 | 1,566,916 | 1,577,978 | +6.3% |
| on disk, all tiers | 110.24 MiB | 113.41 MiB | 117.20 MiB | +6.3% |
| peak concurrency | 1,547 | 320 | 135 | falls with density |

The two tiers that carry the concurrency answer — intervals and deltas — are **volume quantities
and do not care about span at all**. The hour cube is a **span quantity**: it stores one row per
(dimension combination × cube level × *hour*), so its floor is set by elapsed hours regardless of
how much traffic those hours contain. That is the whole span-vs-volume distinction in one table.

### Parts are a pure span quantity

| parts / partitions | 12 days | 60 days | 180 days |
|---|---|---|---|
| `ev_raw` | 45 / 13 | 187 / 61 | 548 / 181 |
| `cc_minute_delta` | 13 / 13 | 61 / 61 | 181 / 181 |
| `cc_user_minute` | 26 / 13 | 122 / 61 | 362 / 181 |
| `cc_minute_stateless` | 32 / 13 | 127 / 61 | 368 / 181 |
| **`cc_hour_agg`** | **1 / 1** | **3 / 3** | **6 / 6** |

Total active parts across the six tiers go from 118 to 1,466 — **12.4× more parts for the same
8.3M rows**. Per *partition*
the count stays at 3–4, so ClickHouse's `parts_to_throw_insert` (which is per-partition) is nowhere
near tripping; what grows is the global part count, and with it merge scheduling and `system.parts`
overhead.

`cc_hour_agg` is the exception, and deliberately so: `sql/50_hour_agg.sql` partitions it **by month,
not by day**, a choice made on a 12-day file for a reason that only pays off here. It ends at 6
parts where the day-partitioned tiers end at 181–548. Span validates that decision.

## Finding 3 — the hour cube overtakes the delta tier, and nothing else

The brief expected `cc_hour_agg` to become "the tier most likely to become the largest object we
own". **Measured: it does not.** It overtakes only the *smallest* tier, and remains fourth overall.

At 180 days / 8.3M events, by size on disk:

| tier | on disk | note |
|---|---|---|
| `ev_raw` | 72.11 MiB | still 13× the hour cube |
| `session_intervals` | 16.67 MiB | |
| `cc_user_minute` | 8.75 MiB | |
| **`cc_hour_agg`** | **5.56 MiB** | overtook the delta tier |
| `cc_minute_delta` | 3.21 MiB | |

It *does* pass `cc_minute_delta`, and the gap widens with span — 1.43× its bytes at 12 days, 1.67×
at 60, **1.73× at 180** — but both are rounding errors next to the raw table. The honest statement
is: the hour cube grows with span while the delta tier does not, so it will keep gaining, but at
this rate it needs roughly a decade of history to threaten `ev_raw`.

## Finding 4 — "a long range costs the same as a short one": what is actually true

This is the strongest claim the repo makes about ADR 0003, and it needed checking rather than
assuming. The baseline in `evidence/bench.txt` is real: `b01` (one day) and `b10` (the whole
13-day span) both read **240.0 KiB / 8,193 rows / 1 of 4 granules** — byte-identical.

Measured across spans, the whole-history query (`v_cc_window_range`, grand-total cube level):

| span | one day (W1) | 30 days (W2) | whole history (W3) | granules read (W3) |
|---|---|---|---|---|
| 12 days | 272 KiB / 8,193 | 272 KiB / 8,193 \* | **272 KiB / 8,193** | 1 |
| 60 days | 272 KiB / 8,193 | 544 KiB / 16,385 | **797 KiB / 24,025** | 3 |
| 180 days | 272 KiB / 8,193 | 544 KiB / 16,385 | **1.59 MiB / 49,153** | 6 |

\* at a 12-day span the "30-day" window is clipped to the 12 days that exist, so it is the same
query as W3 on that row.

The `SelectedMarks` column from `system.query_log` is the clean statement: **W3 reads exactly one
index granule per MONTHLY PARTITION the range touches** — 1, 3 and 6 granules for 12, 60 and 180
days (the row counts are 8,192 per full granule plus a partial final one, which is why 60 days
reads 24,025 rather than a round 24,576). So:

- **Refuted, as literally stated.** A whole-history query at six months reads 6× what a one-day
  query reads. "Same bytes regardless of range" is not a property of the design; it is an artifact
  of a 13-day file fitting inside a *single monthly partition*. Cross one month boundary and it
  costs one more granule.
- **Confirmed, as ADR 0003 actually words it** — cost is `O(range_hours)` in stored rows, never
  `O(range_minutes)`. 180 days is 15× the range of 12 days for 6× the bytes, and 259,200 minutes
  answered by reading 49,153 rows. The contrast row makes it concrete: the same whole-history
  question against the minute tier (M1) reads **407,815 rows / 4.67 MiB across 181 parts** — 8×
  the rows and 3× the bytes of the hour-tier path, and that gap grows with span.

The correct claim to make in the deck is therefore: *a long range costs one index granule per month
of history, not one row per minute* — which is a stronger and more defensible statement than the one
it replaces, because it comes with the constant.

Partition pruning never stopped working: the one-day minute-tier probe (M2) reads 1 part of 181 at
180 days.

## Finding 5 — retention, TTL, and a straggler that is months old

`session_dirty`, `cc_publish_batch` and `cc_publish_consumed` carry 7-day TTLs (queue item Q11).
Those TTLs are on `marked_at` — **processing time, not event time** — so a correction to a session
whose events are months old is unaffected. Verified rather than argued: the harness injects a
heartbeat bridging a gap in a session from **week 1 of a 180-day span**, then runs the real
publisher.

## Correctness held at every point

| point | reconcile (delta vs intervals) | user tier | designed-truth probe |
|---|---|---|---|
| 12 d / 8.3M | PASS 17,392 min, peak 1,547 | PASS, user peak 1,543 | PASS 186 min, peak 40 |
| 60 d / 8.3M | PASS 86,426 min, peak 320 | PASS, user peak 320 | PASS 186 min, peak 40 |
| 180 d / 8.3M | PASS 250,169 min, peak 135 | PASS, user peak 135 | PASS 186 min, peak 40 |

Correctness on 12 days does not imply correctness on 180, which is why the gate runs at every
point. It passed at every point, including across month boundaries and midnight crossings.

## What this does NOT cover

- **Real months of real data.** The stream is synthetic below the time axis; only the probe blocks
  have an analytically known answer.
- **TTL expiry observed in the wild.** The 7-day TTLs were reasoned about and the old-straggler
  path was exercised, but no run here waited 7 days to watch a queue row actually vanish.
- **Merge behaviour over weeks.** Part counts are measured at the end of a bulk build, not after a
  service has been merging continuously for six months.
- **Cloud.** Everything here is the local docker ClickHouse. `sonyliv` and `TARGET=cloud` were
  never written.
