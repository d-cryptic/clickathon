# REMAINING — what is actually left, verified rather than remembered

> **Summary:** Checked every open item in `TODOS.md`, `v2.todo.md` and `docs/WORKTREE_QUEUE.md`
> against the live system and the released unseen/submission contracts on 2026-08-02. The old
> “private repo” and “Team Captain” blockers were not in the official rules and are retired. The
> fixed benchmark set/private answer key were also retired: judges spot-check required concurrency
> results against raw events. The portal closes automatically at **12:00 PM IST, 2026-08-02**. Real
> P0s are the hosted demo/video, team folder/PR and live ClickStack evidence.

**Verified:** 2026-08-02, against `main` at the merge of all 234 commits. Gate PASSED — 17,028
minutes, 0 mismatched, peak 2,917. `make ci` green.

**Official unseen update:** the current local release path loaded 7,000,000 rows, built 102 output
dates in 64+38 chunks without a setting override, and reconciled 3,201,716 minutes with zero
mismatches; see `evidence/unseen/official-20260802-codex-validation.txt`.

---

## 1 · Final submission work that cannot be inferred from the code

| # | Item | Why blocked |
|---|---|---|
| **A1** | **Hosted demo and 2–3 minute video are not packaged.** | Both must show the curve, all applicable filters and ClickStack working live. Screenshots alone are not proof. |
| **A2** | **The self-contained official team folder and PR are not assembled.** | Include source, README, architecture, pitch PDF, video/demo links, ClickStack deployment/OTel wiring, redacted `.env.example`, destination service/tables and dashboard/search captures; open `[Submission] Team Name`. |
| **A3** | **Q35 — adopt peak 2,927, or keep 2,917?** | A **decision**, not a bug. A run of one event yields a zero-length segment dropped before `TAIL_S` applies, so 182 runs earn nothing. Keeping them moves the peak **2,917 → 2,927** (+5.0 h; Codex confirmed 80 changed minutes, +18,127 s). We answer "not at all" **by accident, not by choice**. ADR 0031 is being written to present both readings; the signature is yours. |

## 1b · Newly unblocked — the publisher can now safely run on the graded database

Verified 2026-08-02 after the rebuild:

```
 cc_user_minute engine   SharedReplacingMergeTree   ← ADR 0016 shape, was AggregatingMergeTree
 mv_user_minute          GONE                       ← retired, as ADR 0016 requires
 cc_hour_agg.cube_level  present                    ← ADR 0022
 cc_publish_runs         0 rows                     ← still never run
```

**The blocker is cleared.** Until the rebuild, running `tools/publish.sh` against `sonyliv` would
have written replace-semantics rows into a set-union table — the reason its cursor was pinned at
epoch and every doc said "keep it there". The graded database now carries the shape the publisher
expects.

**What this changes.** Codex 008 lists "continuous publication is not deployed on the current schema"
as an operational gap. The *schema* half is now closed; only the *running* half remains, and that is
an operator decision rather than an engineering one. The capability is proven byte-identical to a
rebuild across four tiers in scratch (`evidence/publish.txt`); what is missing is a decision to let
it maintain the graded numbers instead of a batch rebuild.

**Not doing it unasked.** Every live number today comes from a batch rebuild, which is correct and
verified. Switching the graded database to incremental publication changes how our submitted answers
are maintained, and that is a call for a human — especially given a doubled tier was served for hours
today from a *simpler* operation than this one.

## 1c · ⚠ NEW — ADR 0024 is declared but NOT applied to the graded database

Found 2026-08-02 while repairing the truncation suite. `sql/00_schema.sql` declares `ev_raw.extra`
(the `Map` that carries unknown columns), and `sonyliv.ev_raw` **does not have it**.

**Why this matters more than a normal drift.** `dataset_details.md:43` states in writing that the
solution should work as the number of dimensions increases, and the judges repeated it. ADR 0024
exists to satisfy exactly that: a new filter column on the unseen day is carried into `extra` and is
queryable the same day, with no migration and no human awake. **That capability is in the repository
and not on the service.** On the unseen day a new column would be announced by the loader and then
have nowhere to go.

**The fix is one non-destructive statement** — `ALTER TABLE sonyliv.ev_raw ADD COLUMN extra
Map(LowCardinality(String), String) DEFAULT map()` — but it is a schema change on the graded service,
so it is an **operator decision**, and it is the same class as A3 below.

**Related, and cheaper:** `sql/01_policy.sql` (ADR 0032) also needs one `CREATE OR REPLACE VIEW`
against `sonyliv` before its next build. That one is genuinely non-destructive and passes the
destructive-DDL scanner without an override. `tools/build-model.sh` applies it itself at stage 0/6,
so an authorised rebuild handles it — but until then `sql/30` and `sql/90` fail there loudly with
`Unknown table expression identifier 'v_model_policy'`, which is the intended failure rather than a
silent wrong answer.

## 2 · Open engineering — short

**Q30 · Local `default.session_intervals` predates ADR 0012** (no `build_version`), so it cannot be
rebuilt locally. Verified still true. Any "verify locally first" step runs against a shape Cloud has
not had for days. Fix is a local `DROP` + re-apply + rebuild — **local only, nothing graded**.

**Q34 · User concurrency can exceed session concurrency.** 82 cells, worst excess **+1**, zero totals
affected. In flight on `fix/shared-spec-defects`. Fix it because an invariant that "mostly holds" is
not an invariant, not because it moves a number — it does not.

**Q39 · A >100-day unseen file cannot be inserted, and the obvious fix is illegal on Cloud.**
`cc_minute_delta` and `cc_user_minute` are `PARTITION BY toYYYYMMDD(minute)` — one partition per day —
and ClickHouse Cloud pins `max_partitions_per_insert_block` **read-only at 100**. Measured
2026-08-02 against the graded service:

```
SELECT 1 SETTINGS max_partitions_per_insert_block = 256
  -> Code: 452. Setting max_partitions_per_insert_block should not be changed.
```

So a single INSERT block spanning more than 100 distinct days fails with a 252, and raising the limit
in `SETTINGS` fails with a 452 — the override is not a fix, it is a second, unconditional failure. An
agent added exactly that line to `sql/40_deltas.sql` and `sql/45_user_concurrency.sql`; it was reverted
before it could turn a working build into a guaranteed one. **Do not reintroduce it.**

**CORRECTION, same day.** An earlier version of this entry said the "102 calendar dates" figure was
unsupported and came from `tools/timespan-gen.sh`'s synthetic fixture. **That was wrong, and the
correction was the error.** The figure is real and measured from the **official unseen file**, which
has since been released: 7,000,000 rows whose derived intervals span **102 distinct dates**, from
2021-01-27 to 2026-08-03, despite the file being described as a single day
([009 §3](codex-validation/009-official-unseen-schema-evolution-and-submission-readiness.md)). I
measured the *old* 7-day sample, found 7 dates, and called a correct claim unsupported. The agent that
raised it had the premise right and only the fix wrong.

**RESOLVED, same day — this entry is now history, not an open item.** The Codex session landed a
bounded date-chunk build and ran the official file end to end
(`evidence/unseen/official-20260802-codex-validation.txt`, 07:56):

```
No max_partitions_per_insert_block override was used. The canonical builder
handled 102 output dates as two Cloud-legal chunks of 64 and 38 dates.
ev_landing 7,000,000 = ev_raw 7,000,000 + cast rejects 0
accepted input 6,999,997 / lossless raw 7,000,000; quarantined 3
PASS; minutes_compared=3,201,716; mismatched=0; max_abs_diff=0
```

That is fix (a) below, and it is the right one: no setting override, and the gate reconciled 3.2M
minutes with zero mismatches — so it proved **curve equivalence**, not merely that the INSERT
succeeded, which is what this entry demanded of any fix. `tools/chunked-backfill.sh` and its suite
(`130 sparse dates stay below the Cloud partition cap with exact output`) were **still untracked** as
of `8dd7e0e`; they need committing before the number can be claimed from `main` rather than from one
working tree.

**What was true before it landed**, kept because the reasoning is what makes fix (b) still worth
considering: the user stage died with `TOO_MANY_PARTS`, and there was no unseen answer to submit. Two
fixes work on Cloud:

- **(a) bounded date-chunk build** — drive each tier in slices of well under 100 dates. A `tools/`
  change, no schema change, needs no authorisation. 009 §9 calls this "the safe deadline option" and
  reports it in validation. **This is the one to land.**
- **(b) `PARTITION BY toYYYYMM(minute)`** — 102 days becomes 6 partitions. Strictly better long-term,
  and daily partitioning is over-granular regardless (see the vendored ClickHouse partitioning
  guidance). But it is a **schema change**, so per the standing instruction it is an **operator
  decision**, not a task an agent may take.

Whichever lands must prove **curve equivalence to the unchunked build**, not merely that the INSERT
succeeded. A chunked build that silently drops a boundary minute is worse than one that fails loudly.

**Q40 · No suite asserts its inputs exist, and one suite hides the absence.** `data/*.csv` is
gitignored (`.gitignore:11`), so a fresh `git worktree add` produces a working environment with **no
corpus**. Two suites meet that same missing prerequisite and fail in opposite directions:

- `landing-test.sh` has no fallback, so it **fails loudly** — "missing data/ch-hackathon-raw-data.csv".
- `golden-gen.sh:47-50` has a fallback that reaches into the shared checkout, so it **passes** — and
  writes a machine-absolute path into `evidence/golden/run-*.txt`.

**The one that passed is the more dangerous.** It produced a green suite and committed a
machine-specific path. Worse than first reported: the fallback is not a relative resolution, it is a
hardcoded `$HOME/Developers/personal/clickathon-project/data/...` — one developer's directory layout,
committed in a script the judges may run.

**The fix is not the path resolution.** It is that **nothing checks a suite's inputs before it reports
a verdict** — `grep -l 'require_corpus|assert_inputs|check_data' tools/*.sh` returns nothing. Golden's
fallback should be **removed rather than copied to the others**, so that a missing corpus fails the
same way everywhere, loudly, instead of being silently papered over in the one place someone thought
to paper it.

This is the fourth instance in one day of a single shape — an artifact that looks fine where the
**absence** is the signal. The other three: a two-sided test reporting `CONVERGES` on both halves with
its sabotage half silent; a tally reading `3 passed · 2 failed · 8 skipped` with five suites absent;
an evidence file with its header and no body. `tools/evidence.sh` (`044c703`) closes the third for one
writer; **seven writers and every suite's inputs remain unchecked.**

**Independent validation of `main`.** 234 commits landed at once and **nothing reached `main` through
the six-check gate** — seven attempts, seven rejections, all correct. A Codex audit of `main` as a
submission is running. This is the largest genuinely-open item.

## 3 · Stale — verified done, never struck

These appear open in `TODOS.md` and are not:

| listed as open | actually |
|---|---|
| Tail-sensitivity sweep (gap × tail grid) | **done** — `evidence/params/sweep.tsv`; `TAIL_S` is 7.2× more elastic than `GAP_S` |
| Straggler correction-by-diff + late-arrival demo | **done** — `evidence/publish.txt`, and `demo/replay.sh` shows a historical minute correcting itself |
| H5 hot tier (`mv_lease` → `cc_minute_hot`) | **declined**, ADR 0005/0013 — leases would count paused time as watching, 834 h of exposure against a 1,949 h answer |
| `proj_by_session` projection | **decided**, ADR 0021 — it is live on the graded table |
| Q26 sentinel collision | **fixed**, ADR 0022, merged and applied |
| Q32 nondeterministic peak minute in live views | **fixed** — 0 offending views remain; the rebuild deployed the corrected SQL |
| Q33 bug-11 env clobber | **fixed** — both `build-model.sh` and `reconcile.sh` capture the caller's environment first |
| Q36 `load.sh --replace` unguarded | **fixed** — refuses the graded database without `REPLACE_GRADED` |

**The lesson worth keeping:** a list of open items that is 8/12 stale is worse than no list, because
it hides the four that are real. This file exists because the queue stopped being trustworthy.

## 4 · Deliberately not built, and defensible

- **LLM explanation layer for a fired decline alert** — the spec says LLM layers are welcome "where
  they add real value". The detector and its three-way classification are built; an LLM adds nothing
  to detection and something only to phrasing. A well-argued "we chose not to" is a stronger answer
  than a bolted-on call.
- **Langfuse emitter** — optional. ClickStack is the selected integration; adding a second tool does
  not close the missing ClickStack screenshots, hosted-demo walkthrough or video walkthrough.
- **LibreChat conversational layer** — optional for the same reason. The ClickStack code path is
  implemented, but official judge-facing evidence remains incomplete until §1 is closed.
- **Tombstones instead of the per-run interval `DELETE`** — right in principle (ClickHouse's
  avoid-mutations guidance), measured at 1.4 s per run, not worth destabilising a passing pipeline
  before a deadline.

## 5 · Eleven mentor questions, if a mentor becomes available

Ranked in [`doubts/README.md`](doubts/README.md). Ask these three first — they are worth more than
everything below them combined:

| | worth |
|---|---|
| [09](doubts/09-minute-membership-instant-reading.md) any-overlap vs presence-at-the-instant | **−14.1%** |
| [04](doubts/04-dimension-normalisation.md) Hindi is four strings | **23.3%** on per-language answers |
| [10](doubts/10-fail-closed-state-gates.md) must foreground **and** playing both hold? | **−10.7%**, and two independent implementations agree within 2.4% |

**The costs do not add up** — they overlap, and several are measured against the same baseline. Each
is "what this one convention is worth if we have it backwards."
