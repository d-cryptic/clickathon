# PREPROCESSING_PLAN — handling erroneous data (empty / null / duplicate / malformed)

> **Summary:** The model currently has **no preprocessing stage**. Its stance is "prove the hazard
> inert or absorb it by construction" — which genuinely covers event-level duplicates
> (`evidence/dedup.txt`), NULLs (non-Nullable schema), and empty strings (they flow through as
> buckets). But nothing *validates* input, a CSV reload **doubles** the data, dimensions are
> un-normalised, and tied timestamps are mishandled. This plan adds a thin validation + hygiene
> layer without abandoning the prove-inert philosophy, and states where each piece lands in the
> existing `load → ev_raw → intervals → deltas → gate` workflow.

**Status:** plan only — nothing below is implemented. Items ordered by implementation sequence.
**Principle kept:** raw values are never mutated in `ev_raw`; cleaning is either *rejection at the
door*, *derived columns*, or *proven unnecessary*. Ground truth is matched on shipped strings.

---

## Where preprocessing fits

```
 CSV ──▶ [P1 VALIDATE + P2 IDEMPOTENT LOAD] ──▶ ev_raw ──▶ 30_build_intervals [P4 tie fix]
                    │                              │
                    └─▶ ev_raw_rejected (P1)       └─▶ [P3 _norm columns] ──▶ 40_deltas ──▶ gate
                                                                               [P4 mirrors tie fix]

 make model        gains a phase 0: validate, fail-fast on hard violations
 tools/unseen-run.sh  runs the SAME validation — that is where this earns its keep
 /reconcile        unchanged, still the arithmetic gate; validation is the INPUT gate it cannot be
```

---

## P1 · Ingest validation gate  *(new: `sql/05_validate.sql` + hook in `tools/build-model.sh` and `tools/unseen-run.sh`)*

One query over the freshly loaded `ev_raw` + `content_dim`, emitting a summary row per check to
`evidence/validate.txt`. Hard failures exit non-zero before the model builds.

| check | hard/soft | today's expected value |
|---|---|---|
| row count == source line count − header | HARD | 905,558 |
| `video_session_id` / `user_id` match `^[0-9A-F]{64}$` | HARD (count ≠ 0 → fail) | 0 malformed |
| `event_timestamp` inside a sane range (e.g. 2020–2030), not epoch-0 | HARD | 0 |
| `event_timestamp < session_start_epoch` (negative skew) | soft (report) | 0 |
| unknown `event_type` (outside the 7 known) / new `event` values | soft — the unseen day may legitimately add some | 0 / 0 |
| duplicate rows on full row hash, and on (session, ts, event_type, event) | soft | 4,209 / 4,210 |
| empty-string counts per dimension column | soft | audio 1,991 · subtitle 2,006 |
| orphan `content_id`s (events with no catalog row) | soft — LEFT+`'(unknown)'` already absorbs | 0 |
| `content_dim.content_id` uniqueness | HARD | 33,464/33,464 |

Rows failing HARD row-level checks (malformed ID, insane timestamp) go to `ev_raw_rejected`
(same schema + `reject_reason String`), never silently into the model. On today's file that table
is empty — **the empty table plus the report IS the evidence** the checkpoint asks for.

## P2 · Idempotent load  *(fix in `tools/load.sh`; closes C.5 #13)*

- A reload currently **doubles** `ev_raw` (`non_replicated_deduplication_window` is per-batch only).
  Fix: load into a staging table, then atomically `TRUNCATE ev_raw` + move — or guard with a
  pre-count and refuse to load into a non-empty `ev_raw` without an explicit `--replace`.
- Fix `CH_DATABASE` being silently ignored by the load path (same C.5 #13 record).
- Evidence: load twice, show count is still 905,558.

## P3 · Normalisation as *derived* columns  *(new: `sql/07_normalize.sql` dictionary/map; closes C.5 #3; needs a mini-ADR)*

Never rewrite raw values — the private key is matched on shipped strings. Instead:

- A small mapping table `dim_norm` (raw → canonical): `hin/HIN/hin-hindi/hin-Hindi → hin`,
  `jap/jpn → jpn`, `UNK/unk/UND/und/off/OFF/'' → '(none)'`, `Mweb → MWEB`, `5.0.36.00 → 5.0.36`,
  `-soundhandler → '(invalid)'`, `'' video_type → '(untyped)'`.
- Applied where dimensions are *served*: either as `*_norm` columns attributed in
  `30_build_intervals.sql` alongside the raw ones, or (cheaper) at query time in the views via the
  mapping dictionary. Decide at implementation; record in the ADR. Raw columns stay untouched either
  way, so answer-key matching is unaffected.
- Evidence: `WHERE audio_language_norm = 'hin'` returns 703,524-row coverage vs 610,889 raw.

## P4 · Same-second tie fix  *(one-character change, TWO files; closes C.5 #1 — 41.5 h / 2.1%)*

`arrayFirst(x -> x > p, resumes)` misses a resume in the same truncated second. Change `>` → `>=`
in **both** `sql/30_build_intervals.sql` and `sql/90_reconcile.sql` — they share the SPEC, so both
move together (same discipline as `UNCLOSED_PAUSE_TO_RUN_END`). Rebuild + `/reconcile` + re-record
the peak. Guard: a resume at exactly the pause's second now closes a zero-length window — confirm
`arrayFilter(x.2 > x.1)` drops it and the pause is then governed by the unclosed-pause rule; measure
before shipping.

## P5 · Dedup stance — re-prove, don't add  *(extend `evidence/dedup.txt` protocol)*

Event-level dedup stays **proven-inert rather than performed** — that is the stronger answer.
But the proof is a property of *this* file, so the dedup-inertness query joins the unseen-day
runbook: after loading the unseen file, re-run raw-vs-`LIMIT 1 BY` and record 0 differing minutes
(or, if it differs, dedup becomes a real step that day — the query already exists to do it).

## P6 · Say it out loud  *(docs/deck)*

The checkpoint is partly rhetorical. One deck slide / README section: "erroneous data — what we
reject (P1), what we absorb (nulls by schema, orphans by LEFT+default), what we proved harmless
(duplicates, 0/3,725 minutes), what we normalise (P3), and what we deliberately leave raw (ground
truth string matching)."

---

## Order, cost, and what each unblocks

| # | item | effort | closes | evidence artifact |
|---|---|---|---|---|
| 1 | P4 tie fix | ~15 min | C.5 #1 (41.5 h) | reconcile PASS + new peak |
| 2 | P2 idempotent load | ~30 min | C.5 #13 | double-load count stays 905,558 |
| 3 | P1 validation gate | ~1 h | the checkpoint itself | `evidence/validate.txt`, empty `ev_raw_rejected` |
| 4 | P3 normalisation | ~1 h + ADR | C.5 #3, #B.7 | norm-column coverage query |
| 5 | P5 unseen re-proof | ~10 min (wiring) | dedup claim on unseen day | dedup delta = 0 in unseen evidence |
| 6 | P6 narrative | deck time | grader legibility | slide |

**Interactions to respect:** P4 changes the headline peak — run before any number lands in the deck.
P3 must not touch run-splitting (`ts` stays byte-identical — same guarantee `dim_events` made in
`8bfeeb2`). P1 runs before `30_build_intervals` in `make model` and inside `unseen-run.sh` phase
order. Nothing here touches `40_deltas.sql` or the serving-layer math.
