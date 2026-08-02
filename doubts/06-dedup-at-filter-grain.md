# 06 · Duplicates are provably inert for the headline — and provably NOT for filtered answers

> **Summary:** [evidence/dedup.txt](../evidence/dedup.txt) proves the file's 4,210 duplicate rows
> change nothing — at the grain it measured: interval boundaries, totals, the unfiltered curve. The
> model now answers at **seven dimensions**, and the attribution rule (ADR 0008/0009) is a
> frequency **vote** — exactly the multiplicity-sensitive aggregate the old proof's own guard (a)
> warned about. Re-measured A/B (raw vs deduplicated): boundaries **byte-identical**, 30,323
> intervals / 1,978.1 h / peak 2,917 both arms — but **6 intervals flip audio_language**, the
> `hin`/`non`/`unk` curves move across **18/15/26 minutes**, and the `unk` audio peak goes
> **183 → 184**. Upstream step 3, "deduplicate late or repeated events", is therefore **not
> validated for dimensioned answers**. The reconcile gate compares per-minute **totals only**, so it
> can never see this. **Scopes `evidence/dedup.txt`; policy ADR 0016 reserved pending the answer.**

**Status:** open · **Evidence measured:** 2026-08-01, ClickHouse Cloud `sonyliv`, current model
(30,323 intervals · 1,978.1 h · peak 2,917); A/B is a full re-derivation of
`sql/30_build_intervals.sql`, run twice inside one query

---

## The evidence

### 1 · What changed since the proof: the model started counting

`evidence/dedup.txt` (2026-08-01, earlier model generation: 30,769 intervals, peak 2,887, dimensions
platform/country/content_id) proved inertness mechanically: run splitting, pause folding and
`is_open` read the event stream as a **set** of instants, and a duplicate can never change a set.
Its section 5(a) named the condition under which the verdict dies:

> "THE MODEL STAYS MULTIPLICITY-INSENSITIVE. Any aggregate over ev_raw that COUNTS events rather
> than reading their timestamps as a set breaks immediately."

ADR 0008/0009 then made dimension attribution a **dominant-value vote** —
`arraySort(v -> (-countEqual(values, v), v), arrayDistinct(values))[1]` — per interval, over seven
dimensions. `countEqual` counts events. The guard fired; nobody re-ran the A/B until now.

### 2 · The A/B — boundaries identical, so every total is identical

The full `sql/30_build_intervals.sql` derivation run twice in one query: arm 0 over `ev_raw` as-is,
arm 1 deduplicated **deterministically** (winner pinned, so the arms are comparable):

```sql
SELECT * FROM ev_raw
ORDER BY video_session_id, event_timestamp, event_type, event, subtitle_language
LIMIT 1 BY video_session_id, event_timestamp, event_type, event      -- 905,558 → 901,348 rows
```

| arm | intervals | hours | cityHash64 of all (session, start, end) |
|---|---:|---:|---|
| 0 — raw | 30,323 | 1,978.1 | 1595692701993512111 |
| 1 — dedup | 30,323 | 1,978.1 | **1595692701993512111** — identical |

Identical boundaries ⇒ the unfiltered curve, the 2,917 peak, and the watch-hours total are
unchanged **by construction**. The old proof's core still holds — at its grain.

### 3 · Six intervals change their answer to "what was being watched"

Joining the arms on `(session, interval_start, interval_end)` and comparing all seven dimensions:

| session (prefix) | interval start | dimension | raw → dedup |
|---|---|---|---|
| `3575B56C…` | 10:52:15 | audio_language | `unk` → `hin` |
| `38BDE681…` | 10:53:12 | audio_language | `non` → `unk` |
| `45B2EF62…` | 10:36:32 | audio_language | `hin` → `unk` |
| `86F3F1CD…` | 10:34:39 | audio_language | `hin` → `unk` |
| `9A5DAE7B…` | 10:36:15 | audio_language | `non` → `hin` |
| `AFAB4001…` | 10:30:28 | audio_language | `non` → `hin` |

All six are `audio_language`; the other six dimensions never flip on this file. The mechanism, on
the first one (session `3575B56C4807737BCEDE99C1AF1D9EF569C7A253F6707D26C5BBF540005FDB21`, interval
10:52:15 → 10:52:43):

```
 raw    votes: unk 11 · hin 5     → unk wins on count
 dedup  votes: unk  5 · hin 5     → dead tie; tie-break "by the value itself" → hin
```

Six duplicated `unk`-carrying heartbeats are the entire majority. The vote is deterministic in both
arms — determinism was ADR 0009's goal and it is intact — but it is a **different deterministic
answer** depending on whether replayed events count as extra ballots.

### 4 · What a filtered benchmark answer sees

Curves computed exactly as the serving layer does (minute-grain merge per session, first interval's
dimensions win per merged run, then per-minute counts by `audio_language`):

| audio_language | minutes differing | max per-minute diff | peak raw | peak dedup |
|---|---:|---:|---:|---:|
| `hin` | 18 | 2 | 1,774 | 1,774 |
| `non` | 15 | 1 | 30 | 30 |
| `unk` | 26 | 2 | 183 | **184** |

Unfiltered: **zero** differing minutes. So the headline is safe and any query with an
`audio_language` filter is not — small on this file (≤2 viewers per minute), but it is a
*definitional* wobble, not noise, and the duplicate rate on the unseen day is not ours to choose.

### 5 · No gate can catch it, even in principle

`sql/90_reconcile.sql` compares per-minute **totals** — `uniqExact(video_session_id)` against the
summed deltas — and carries no dimension columns at all. Its truth path even `SELECT DISTINCT`s the
timestamps (boundaries are multiplicity-safe, as §2 confirms). A dimension attribution error of any
size passes the gate by construction. The only defence is deciding the policy *before* a filtered
benchmark answer is generated.

---

## Exactly what to ask

> "Your pipeline statement lists 'apply foreground-only filtering and **deduplicate late or repeated
> events**' as step 3. The shipped file contains 4,210 duplicated rows — replays of the same
> (session, timestamp, event_type, event), 2–6 copies. We measured their effect end to end: they
> change **nothing** about interval boundaries, total watch hours, or total concurrency (peak 2,917
> either way). But our per-interval dimension attribution is a frequency vote over events, and there
> they *do* vote: deduplicating flips the audio-language attribution of 6 intervals and moves the
> per-language curves by up to 2 viewers on 59 minutes.
>
> **The question:** do judge spot-checks deduplicate repeated events before computing
> dimension-filtered answers — and if so, on what key? Or is the stream taken as delivered, so a
> replayed event legitimately carries extra weight?
>
> We ask because both models are self-consistent, the difference is invisible to any total-level
> check, and it decides whether a filtered answer we submit (e.g. peak concurrency for `unk` audio:
> 183 raw vs 184 deduplicated) matches yours."

---

## Why this is worth mentor time

**It is the cheapest possible insurance on every dimension-filtered benchmark answer.** The answer
is one sentence — "we dedup on key X" or "we don't" — and it cannot be recovered from the data:
both arms are internally consistent, our gate compares totals only (§5), and a wrong choice is
silently wrong on exactly the queries the filter matrix grades. The magnitude here is small (≤2
viewers/minute), but the *mechanism* scales with the duplicate rate, and the unseen day's duplicate
rate is unknown — `evidence/dedup.txt` §5(c) already ships the detector for a qualitatively worse
duplicate population.

It also closes out an upstream requirement honestly: step 3 of the stated pipeline is currently
implemented as a **measured no-op**. That claim was true at headline grain and is now known false at
filter grain — we should be able to say which one we ship, and why, with the graders' definition
behind it.

## How the answer changes what we build

| If they say | We change | Cost | Effect |
|---|---|---|---|
| **"judges dedup exact replays"** | add the deterministic dedup (the `ORDER BY … LIMIT 1 BY` above, tie-break recorded) at the head of `per_session` in `sql/30_build_intervals.sql`; record the policy in ADR **0016**; rebuild + `/reconcile` | one extra pass over ev_raw per rebuild; ~4 lines + ADR | 6 intervals re-attributed; `unk` audio peak becomes **184**; headline untouched |
| **"stream as delivered — multiplicity is real"** | nothing in SQL; ADR **0016** records that replayed events intentionally carry vote weight | ADR only | current numbers stand (`unk` peak **183**) |
| **"dedup, but on a different key"** (e.g. ignoring `event`, or full-row) | re-run this A/B with that key before touching the model — the winner-pinning tie-break matters if the key leaves conflicting rows (the one `UNK`/`OFF` subtitle conflict in `evidence/dedup.txt` §1) | one query, then as row 1 | unknown until measured |
| *no answer received* | keep raw multiplicity; the deck states the sensitivity (6 intervals, ≤2 viewers/minute, one filtered peak ±1) next to the other definitional forks; `docs/RUNBOOK_UNSEEN.md` re-runs this A/B whenever `evidence/dedup.txt` §5(c)'s detector fires on the unseen day | zero | bounded and visible instead of silent |

## Our current assumption

The stream is taken as delivered: no dedup pass, replayed events vote. That was a **proven no-op**
at the grain the proof measured and is a **choice** at the grain we now serve. We keep it because
adding an unconfirmed dedup would trade one unvalidated reading for another while costing a rebuild
pass — but it is now a stated policy awaiting confirmation, not an inertness fact.

## Answer

_unrecorded_
