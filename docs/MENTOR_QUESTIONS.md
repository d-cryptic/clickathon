# MENTOR_QUESTIONS — what only the organisers can answer

> **Summary:** Seventeen questions for a SonyLIV/ClickHouse mentor, ranked by how much the answer
> changes what we build. The ground truth is **private**, so none of these can be measured our way out
> of — a wrong guess is silently wrong on every benchmark answer and we would never see it. Tier 1 can
> invalidate the activity model itself (which heartbeat events count, the unclosed-pause rule,
> session-vs-user, timezone, exact-vs-tolerance, and **Q17 — the organiser's own docs say the heartbeat
> is 1/min and the shipped data says 4.72/min**). Tier 2 is boundary semantics that are cheap now and
> expensive at hour 18. Tier 3 is logistics. **Record answers inline as they arrive** — this file
> becomes the spec we build against. Measured evidence backing these:
> [ADR 0007](adr/0007-gate-answers-pause-needs-explicit-handling.md).

## How to use this

- Ask **Tier 1 first**. If mentor time is short, questions 1, 2, 4 and 17 are the ones that can force a
  rewrite rather than a re-run.
- **Numbering is append-only.** A new question goes on the end of its tier keeping the next free
  number, so `Q4` means the same thing in every commit, ADR and worksheet that cites it.
- Each question carries **our current assumption**, so the mentor can confirm or deny rather than
  compose an answer from scratch. That is the fastest possible use of their time.
- **Write the answer into the `Answer:` line in the same sitting**, then update the affected ADR or
  tunable in the same commit — per the repo doc rule. An answer that lives only in someone's memory
  is worth nothing at hour 18.

## Lead with this — it buys credibility and may pre-empt Q1 and Q2

> "We measured that heartbeats effectively **stop** while the app is backgrounded — 0.047/min against
> 4.72/min while active, a 100× drop — so a gap threshold detects backgrounding correctly. But
> heartbeats **survive a pause**: 0.756/min, one event every ~79 seconds, comfortably inside any sane
> gap threshold. So a gap-only model silently counts paused time as watching, which the statement
> explicitly forbids. We've made the model a hybrid. What we can't determine from the data is where
> you draw the line in the ground truth. One more thing while we're here: your dataset doc says the
> heartbeat is passed every minute — the file we got runs at **4.72/min with a p50 inter-arrival of
> 0 seconds**, so we derived our thresholds from the data rather than the doc. If the ground truth
> assumed a 1-minute beat, we'd want to know now rather than at submission." (Q17.)

That shows we found the trap rather than fell into it, and it frames every question below as a
definition question rather than a competence question.

---

## Tier 1 — can invalidate the model

### Q1 · Which `VideoHeartbeat` events count as active playback?
`VideoHeartbeat` is not a periodic beat. Its `event` sub-column is discrete player telemetry —
`network-activity`, `buffer-health`, `video-resize`, `BufferStart`, `Seek`, `pause`, `resume`.
Inter-arrival within a session: **p50 = 0s, p90 = 40s, p99 = 49s**, mean 12.4s, rate **4.72/min**.

**Ask:** Does the ground truth treat *every* `VideoHeartbeat` row as evidence of watching, or only a
subset representing actual playback progress?
**Why it matters:** this is the root of the activity definition. If it's a subset, every downstream
number is wrong regardless of how good the serving layer is.
**Our assumption:** all `VideoHeartbeat` rows count, minus explicitly paused windows.
**Answer:** _unrecorded_

### Q2 · The unclosed-pause rule
27,340 `pause` vs 31,780 `resume`. **6,272 pauses (23%) never resume.** After an unclosed pause,
activity runs at 1.17 beats/min — a quarter of the active rate, so neither clearly watching nor
clearly gone.

**Ask:** Does an unclosed pause stay paused to the end of its run, or end at the next event?
**Why it matters:** run end to end over the real file, the two rules differ by **99.3 h — 5.09%** of
counted watch time (conservative 1,949.3 h vs permissive 2,048.6 h). This is the single largest
unresolved number in the model. *(An earlier draft of this line said ~19,800 minutes / 330 h, taken
from the raw time following an unclosed pause; that overstated it ~3×, because most of that time is
already excluded by the gap rule closing the run. Corrected per
[ADR 0007](adr/0007-gate-answers-pause-needs-explicit-handling.md).)*
**Our assumption:** conservative — stays paused to the end of the run; never credit time we cannot
prove was active. Tracked as `[H2a]` in [TODOS.md](../TODOS.md).
**Answer:** _unrecorded_

### Q3 · Why are there more resumes than pauses?
4,440 more `resume` than `pause`.

**Ask:** Is there an implicit pause we cannot see — ad break, buffering stall, app lifecycle — that we
should be treating as paused time?
**Why it matters:** if an unpaired `resume` implies an unlogged pause, there is inactive time we are
currently crediting as watched, and it is invisible to us.
**Our assumption:** unpaired resumes are noise and are ignored.
**Answer:** _unrecorded_

### Q4 · Session-level or user-level concurrency?
The statement says "count how many *sessions* overlap" in one place and "how many *people* are
watching" / "viewers" elsewhere. We have both `video_session_id` and `user_id`.

**Ask:** One user with two concurrent sessions — is that 1 or 2?
**Why it matters:** structural, not cosmetic. Sessions are summable across dimension buckets; distinct
users are **not** (a user on two contents counts once). User-level forces `uniqExact` state everywhere
and changes the whole aggregation strategy.
**Our assumption:** session-level.
**Answer:** _unrecorded_

### Q5 · Timezone for bucketing
`event_timestamp` is epoch milliseconds.

**Ask:** Are minute / hour / day buckets computed in **UTC or IST**?
**Why it matters:** day-grain answers shift by 5.5 hours. Total, silent failure — every number wrong
and nothing looks broken.
**Our assumption:** UTC.
**Answer:** _unrecorded_

### Q6 · Exact match, or a tolerance?
**Ask:** Is correctness scored on exact equality against the ground truth, or within a percentage band?
**Why it matters:** decides `uniqExact` vs approximate `uniq` (HLL carries 1–2% error), and whether the
tail-credit rule in Q7 must be exactly right or merely close.
**Our assumption:** exact — we use `uniqExact` throughout.
**Answer:** _unrecorded_

### Q17 · Your documentation says the heartbeat is every 1 minute. The shipped data says 4.72/min.
`docs/upstream/dataset_details.md` states: *"The heartbeat event type is a periodic event which is
currently passed every 1 minute."* Measured over the whole 905,558-event file, that is not what
arrived. `VideoHeartbeat` inter-arrival **within a session** is **p50 0s, p90 40s, p99 49s**, mean
12.4s, overall rate **4.72/min** — discrete, bursty player telemetry (`network-activity`,
`buffer-health`, `video-resize`, `BufferStart`, `Seek`, `pause`, `resume`), with no 60-second period
anywhere in it.

**Ask:** Which is authoritative for the ground truth — the documented 1-minute beat, or the event
stream you shipped us? Concretely: was the private ground truth computed with a rule that *assumes*
a 1-minute cadence — "active for the 60 seconds following each heartbeat", or an inactivity timeout
derived as N missed 60-second beats?
**Why it matters:** every tunable in our activity model is a function of the cadence, so the two
readings give different interval boundaries on every session in the file. We derived
`HEARTBEAT_GAP_S = 150s` as ~3× the measured p99 of 49s; a 1-minute-cadence reading would naturally
produce "2 or 3 missed beats" = 120s or 180s. Likewise `TAIL_GRACE_S = 60s` is only "one cadence" if
a cadence exists — otherwise it is an arbitrary constant. If your generator emits at 1/min and the
delivered file was enriched or resampled after that, we have tuned to an artefact of the delivery
rather than to the model you scored, and **every number we report moves** — peak, average and
per-minute concurrency alike, on the benchmark set and on the unseen day.
**Our assumption:** the shipped data is authoritative. Thresholds are derived from the measured
distribution, not from the documented cadence — recorded in
[ADR 0007](adr/0007-gate-answers-pause-needs-explicit-handling.md) and implemented in
`sql/30_build_intervals.sql`. If the answer is "assume 1/min", `HEARTBEAT_GAP_S` and `TAIL_GRACE_S`
are one-line changes plus a `/reconcile` re-run — but we need to know before the benchmark set lands.
**Answer:** _unrecorded_

---

## Tier 2 — boundary semantics · cheap now, expensive at hour 18

### Q7 · Tail credit
A session's last signal is at 10:05:00 and nothing follows.

**Ask:** Is it active until 10:05:00 exactly, or credited some grace period past the last event?
**Why it matters:** unfittable without being told, and it biases every interval in the dataset.
**Our assumption:** 60s of grace (`TAIL_GRACE_S`), a tunable in `sql/30_build_intervals.sql`. It was
originally justified as "one cadence"; per Q17 there is no cadence, so it is now simply a constant we
would like confirmed. Credited only where a run ends by silence — a segment ending at an explicit
`pause` gets none.
**Answer:** _unrecorded_

### Q8 · Minute membership
**Ask:** Is a session concurrent at minute M if it was active for **any part** of M, or only if active
at the **instant** M begins?
**Why it matters:** half-open vs closed intervals — an off-by-one on every boundary in the dataset.
**Our assumption:** any overlap counts.
**Answer:** _unrecorded_

### Q9 · Peak at coarser grain
**Ask:** Is "peak concurrency at hour grain" the max of the 60 per-minute values inside the hour, or
concurrency computed over hour-sized buckets directly?
**Why it matters:** different numbers, and it decides whether
[ADR 0003](adr/0003-hour-clipped-interval-splitting.md)'s hour pre-aggregation answers the benchmark
directly or needs a second path.
**Our assumption:** max of the per-minute values.
**Answer:** _unrecorded_

### Q10 · Average concurrency
**Ask:** Time-weighted across the whole range **including zero-concurrency minutes**, or averaged only
over minutes that had activity?
**Why it matters:** on a sparse content_id filter these differ by a lot.
**Our assumption:** time-weighted over the full range, zeros included.
**Answer:** _unrecorded_

### Q11 · Is buffering watching? Is scrubbing?
A viewer staring at a spinner still emits `buffer-health` and `BufferStart`; scrubbing emits `Seek`,
`video_forward`, `video_rewind`.

**Ask:** Do stalled playback and scrubbing count as active watching?
**Why it matters:** the statement excludes "silent with no heartbeat", but buffering *has* heartbeats —
it is the same shape of trap as pause.
**Our assumption:** both count as active.
**Answer:** _unrecorded_

### Q18 · Is Hindi one audio language or four?
`audio_language` has 41 distinct values and Hindi is four of them — `hin` 610,889, `HIN` 69,033,
`hin-hindi` 23,095, `hin-Hindi` 507. English is another four, Japanese four.

**Ask:** In your ground truth, does a Hindi-audio filter count all four spellings as one language, or
is each string its own filter value? (And: do `UNK` and `UND` mean different things in
`subtitle_language`, which is 91.5% sentinel?)
**Why it matters:** measured, peak Hindi concurrency is **1,768** un-normalised and **2,180**
normalised — **23.3%** on any per-language answer. The unfiltered peak is 2,887 either way, so only
filtered queries are exposed — but `/reconcile` cannot catch this, because it recomputes truth from
the same strings and agrees with itself by construction.
**Our assumption:** store raw, normalise on read, and report the normalised figure. See
[ADR 0009](adr/0009-normalise-filter-dimensions-at-query-time.md) and the dossier at
[doubts/04](../doubts/04-dimension-normalisation.md) — switching readings is a `WHERE` clause, not a
rebuild.
**Answer:** _unrecorded_

---

## Tier 3 — logistics that shape the build

### Q12 · When do we get the benchmark query set?
We do not have it yet. Its exact shapes decide what is worth pre-aggregating; guessing wrong wastes the
pre-aggregation budget on the wrong grain.
**Answer:** _unrecorded_

### Q13 · How is query latency measured?
Cold or warm cache? First run or median of N? And **which counter** do judges read for "what your
queries read" — `read_rows`, `read_bytes`, or granules touched?
**Why it matters:** we label every benchmark run with `log_comment` for evidence; we want to capture
the metric that is actually scored.
**Answer:** _unrecorded_

### Q14 · Unseen-day guarantees
Same schema and event types? Will it contain **more than one `country`** (we have exactly one, so a
country-filter bug is invisible in testing)? Same planted poison rows, like the negative `content_id`?
A single day, or the same ~11.8-day span?
**Answer:** _unrecorded_

### Q15 · What counts as "meaningful" integration?
Is instrumenting our own pipeline's ingestion lag, watermark lag and query latency in ClickStack
sufficient, or do you want it user-facing?
**Answer:** _unrecorded_

### Q16 · What scale should we defend at?
"100×" is mentioned in the statement — **100× of what**: sessions, events, or peak concurrency?
**Why it matters:** the three imply different bottlenecks and we would defend different trade-offs.
**Answer:** _unrecorded_

---

## Answer log

| Date | Who | Questions answered | Landed in |
|---|---|---|---|
| _—_ | _—_ | _—_ | _—_ |

When a question is answered, fill the `Answer:` line above, add a row here, and update the affected
ADR or tunable **in the same commit**.
