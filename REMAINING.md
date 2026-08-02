# REMAINING — what is actually left, verified rather than remembered

> **Summary:** Checked every open item in `TODOS.md`, `v2.todo.md` and `docs/WORKTREE_QUEUE.md`
> against the live system on 2026-08-02. **Most were stale — done, decided or declined, and never
> struck.** What genuinely remains is small: **two administrative blockers only a human can clear**
> (the repo is private, no Team Captain), **one open decision** (Q35 — adopt peak 2,927 or keep
> 2,917), **one local-only defect** (Q30), and **independent validation of `main` as a whole**, which
> is running. Everything else on those lists is finished. If you read one section, read §1.

**Verified:** 2026-08-02, against `main` at the merge of all 234 commits. Gate PASSED — 17,028
minutes, 0 mismatched, peak 2,917. `make ci` green.

---

## 1 · Only a human can do these — and two are disqualification-level

| # | Item | Why blocked |
|---|---|---|
| **A1** | **The repo is PRIVATE.** Submission requires public. | Owner-only. Pre-publication checklist in [`SUBMISSION.md`](SUBMISSION.md) — note the Cloud **hostname** appears in `evidence/load-guard.txt` and in history at `6355048`. A hostname grants no access; decide deliberately rather than by default. |
| **A2** | **No Team Captain is named.** | Only the Captain can submit. |
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

## 2 · Open engineering — short

**Q30 · Local `default.session_intervals` predates ADR 0012** (no `build_version`), so it cannot be
rebuilt locally. Verified still true. Any "verify locally first" step runs against a shape Cloud has
not had for days. Fix is a local `DROP` + re-apply + rebuild — **local only, nothing graded**.

**Q34 · User concurrency can exceed session concurrency.** 82 cells, worst excess **+1**, zero totals
affected. In flight on `fix/shared-spec-defects`. Fix it because an invariant that "mostly holds" is
not an invariant, not because it moves a number — it does not.

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
- **Langfuse emitter** — the spec requires *one* of ClickStack/Langfuse/LibreChat. ClickStack is done
  properly, including our own pipeline emitting OTLP.
- **LibreChat conversational layer** — optional; the integration requirement is already met.
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
