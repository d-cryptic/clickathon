# MENTOR_QUESTIONS — what only the organisers can answer

> **Summary:** Sixteen questions for a SonyLIV/ClickHouse mentor, ranked by how much the answer changes
> what we build. The ground truth is **private**, so none of these can be measured our way out of — a
> wrong guess is silently wrong on every benchmark answer and we would never see it. Tier 1 can
> invalidate the activity model itself (which heartbeat events count, the unclosed-pause rule,
> session-vs-user, timezone, exact-vs-tolerance). Tier 2 is boundary semantics that are cheap now and
> expensive at hour 18. Tier 3 is logistics. **Record answers inline as they arrive** — this file
> becomes the spec we build against. Measured evidence backing these:
> [ADR 0007](adr/0007-gate-answers-pause-needs-explicit-handling.md).

## How to use this

- Ask **Tier 1 first**. If mentor time is short, questions 1, 2 and 4 are the ones that can force a
  rewrite rather than a re-run.
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
> you draw the line in the ground truth."

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
**Why it matters:** the two rules differ by **~19,800 minutes** (1,187,790 s) of credited active time.
This is the single largest unresolved number in the model.
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

---

## Tier 2 — boundary semantics · cheap now, expensive at hour 18

### Q7 · Tail credit
A session's last signal is at 10:05:00 and nothing follows.

**Ask:** Is it active until 10:05:00 exactly, or credited some grace period past the last event?
**Why it matters:** unfittable without being told, and it biases every interval in the dataset.
**Our assumption:** one cadence of grace (`TAIL_GRACE_S`), a tunable in `sql/10_intervals.sql`.
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
