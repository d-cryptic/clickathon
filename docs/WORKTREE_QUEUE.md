# WORKTREE_QUEUE — the prioritised work list, brief-ready

> **Summary:** One row per unit of work, ordered so the next worktree can be spawned without
> re-deciding anything. Each entry names the files it OWNS (so parallel worktrees cannot collide), its
> ADR number where one is needed (assign here, never let an agent pick — three agents once all chose
> 0009), and what "done" means. Sourced from the Codex cross-model audit
> [`codex-validation/001.md`](codex-validation/001.md), `checkpoint/1.md` §C5, and
> [`EXPLAINER.md`](EXPLAINER.md) §C.5. **Verify a claim before building on it** — the audit is a
> hypothesis about this repo until re-measured, exactly like any inherited number.

**Reserved ADR numbers:** 0009–0014 used. **Next free: 0015.** Assign from this file.

---

## Tier 0 · Correctness, and it is invisible to our own gate

| # | Work | Owns | Done when |
|---|---|---|---|
| **Q1** | **`sonyliv observe` reports a green gate as FAILED.** Verified live: prints `reconcile pass=false max_abs_delta=0` while the gate says 17,028 minutes / 0 mismatched / PASS. `internal/pipelinehealth/reconcile.go` still parses the old five-column table; the gate now emits `ord` and `scope`, so it parses zero rows and correctly treats "no evidence" as failure. The unit fixture pins the old shape, so tests pass while the parser is broken. | `internal/pipelinehealth/`, its fixtures | `observe` reports `pass=true`; the fixture is regenerated from what `tools/reconcile.sh` writes **today**; a deliberately-failing gate still parses as failure |
| **Q2** | **The publisher does not maintain the user or hour/day tiers.** Verified: `sql/12_publish.sql` and `tools/publish.sh` contain **zero** references to `cc_hour_agg` or `cc_user_minute`. `mv_user_minute` merges `uniqExact` by set union — it can add a user to a minute but **cannot retract one** whose only interval was superseded, which is why `build-model.sh` must truncate it. So minute totals can be current while user concurrency is inflated and hour/day peaks are stale. | `sql/12_publish.sql`, `tools/publish.sh`, `tools/publish-test.sh`, ADR **0015** | both tiers converge after growth, shrink, dimension change and a late straggler; `publish-test.sh` instantiates and compares them (today its scratch DBs have neither table) |
| **Q3** | **Minute-boundary semantics are self-confirming.** The expansion includes `toStartOfMinute(interval_end)`; half-open overlap would exclude it. 505 intervals across 493 sessions hit the case; the alternative moves 91 minutes, 302 viewer-minutes, and the peak 2,917 → 2,916. Both the model *and* `90_reconcile.sql` use the same convention, so a green gate **cannot** choose between them. | `doubts/05-*.md` (new) | a mentor dossier in the existing format: evidence + exact wording + decision table. **Do not change the model** — this is Q8, a definition question |

## Tier 1 · Claims we make that are not yet true

| # | Work | Owns | Done when |
|---|---|---|---|
| **Q4** | **Docs overstate ADR 0013.** `TODOS.md` marks continuous aggregates DONE; `ARCHITECTURE.md` says "Nothing is ever updated or rebuilt" while the finalizer schedules a `DELETE` prune per run; `WALKTHROUGH.md` says "byte-identical" without scoping it to interval/minute-delta; its summary contains both "published incrementally" **and** "batch-rebuilt". Every claim needs one scope and one current number. | `TODOS.md`, `WALKTHROUGH.md`, `docs/ARCHITECTURE.md` | no headline claim exceeds what `evidence/publish.txt` actually proves |
| **Q5** | **Dedup is NOT inert at filter grain.** `evidence/dedup.txt` proved inertness at the old 3-dimension headline. The model now carries 7. Re-measured: same totals and peak, but **6 interval dimension attributions change**, audio-language curves move for `hin`/`non`/`unk` across 18/15/26 minutes, and the `UNK` audio peak goes 183 → 184. Upstream step 3 is therefore unvalidated for dimensioned answers. | `evidence/dedup.txt`, ADR **0016** | the conclusion is scoped to the grain it holds at, and the filter-grain policy is decided and stated |
| **Q6** | **Normalisation is built, ADR'd, and absent from Cloud.** Verified: no `norm_*` UDF or `%norm%`/`%drift%` view exists in `sonyliv`. Now wired as stage 5/5 of `build-model.sh`, so the next rebuild creates it — but nothing creates it today, and the audit measured raw Hindi peak 1,774 → 2,196 normalised, not the 1,791 → 2,213 pair the docs carry. | `sql/15_normalise.sql`, ADR 0011 amendment | applied to `sonyliv` (**operator call — schema change**), docs carry the current pair |
| **Q7** | **`checkpoint/1.md` needs a "current status" pointer.** It is deliberately historical and correctly said publication was batch at that moment. Without a forward pointer a reader mixes it with post-checkpoint claims. | `checkpoint/1.md` header only | one line at the top pointing at `WALKTHROUGH.md`; the body stays frozen |

## Tier 2 · Robustness the audit found by inspection

These are **code-inspection findings, not reproduced incidents** — reproduce before fixing.

| # | Work | Owns | Done when |
|---|---|---|---|
| **Q8** | **Publisher crash window.** `publish.sh` writes `cc_publish_batch`, then `cc_publish_consumed`, then appends `claimed` to `cc_publish_runs`. A failure between steps 2 and 3 leaves the dirty markings consumed with no in-flight run — the batch is orphaned and silently skipped. Phase markers protect everything *after* `claimed`. | `tools/publish.sh`, `sql/12_publish.sql`, ADR **0017** | crash injected at every phase, recovery proven |
| **Q9** | **Concurrent publishers corrupt correction-by-diff.** No lease or compare-and-set around "find in-flight, then claim". Two publishers can claim the same sessions and each negate the same contribution: from `X` the result is `2X' − X`, not `X'`. `run_id` is epoch-ms and not unique across processes. | same as Q8 | a real lease/fencing token, tested with two simultaneous publishers |
| **Q10** | **`marked_at` is not an insert identity.** `cc_publish_consumed` is keyed on `DateTime64(3)` alone. Two same-millisecond inserts where one commits later can permanently suppress the slower one. The 5 s settle reduces probability; it does not establish uniqueness. | same as Q8 | collision-safe identity, tested with same-ms + slow commit |
| **Q11** | **Retention is an unenforced correctness bound.** `session_dirty`/batch/consumed use 7-day TTLs. If publication stalls beyond that, work expires silently. | `sql/12_publish.sql`, observability | an alert on publisher lag vs retention |

## Tier 3 · Evidence and hygiene

| # | Work | Owns | Done when |
|---|---|---|---|
| **Q12** | **Benchmark bundle does not exist.** No `evidence/benchmark/`, no query-log bundle over the minute/hour/day × filter matrix. One 7 ms / 329 KiB query is not dashboard-grade evidence. *(Operator previously parked this pending the official query set — revisit: our own shapes are still evidence where we have none.)* | `evidence/benchmark/`, `.claude/commands/bench.md` | artifact binds query text, params, answers, latency, rows/bytes, query IDs, commit, dataset checksum |
| **Q13** | **ClickStack user sources are invalid.** Persisted sources select `concurrent` against views exposing `concurrent_users`. Full signed-in chart path never validated end to end. **Plus the 7-dashboard build-out** (headline comparison, dimensional drilldown, content, **time-window trend — a required aggregation with no visual at all**, user-level, pipeline health, `system.query_log` cost). Brief ready at `scratchpad/tasks/p3.md`. | `tools/clickstack-*.sh`, `docs/CLICKSTACK.md` | every tile verified signed-in against the graded service; screenshots committed |
| **Q14** | **Demo harness + 5-min video.** Never rehearsed end to end. Brief ready at `scratchpad/tasks/p2.md`. | `demo/` | timed rehearsal committed as evidence; every beat has a committed fallback artifact |
| **Q15** | **`make ci` does not pass cleanly.** It selects global `golangci-lint` v1.64.8 against a v2 config. Coverage: `cmd` 0%, `chdb` 0%, `otelemit` 19.6%, `pipelinehealth` 54.5% — target is 80%. ShellCheck warnings remain in loader-guard and unseen scripts. | `Makefile`, `.golangci.yml`, Go tests | `make ci` green on a clean shell; the Q1 parser and publisher state machine covered |
| **Q16** | **Local target is misconfigured.** Go and several tools read `CH_DATABASE` (Cloud) for local work, so local verify 404s; `tools/ch` uses the server default instead. Local `cc_minute_stateless` is `uniq` where Cloud is `uniqExact`. | `internal/config/`, `tools/ch` | one command targets one database regardless of implementation |
| **Q17** | **7 broken Markdown links; 4 files violate the 7-line-summary rule.** | the offending files | link scan clean |

---

## Rules for spawning from this queue

- **Assign the ADR number from this file.** Three agents once independently chose 0009.
- **One owner per file.** The `sql/` split held perfectly last round; the *docs* collided because no
  owner was named. Name doc owners too.
- **Create worktrees one per shell invocation.** Batching several into one call made later ones fork
  from a cached, stale base.
- **A create that times out may still have launched.** Check `sc workspace list` before retrying —
  retrying blind produced a duplicate deck worktree.
- Every brief carries: target branch `dev`, never push to `main`, measurements not conclusions, and
  `make reconcile` must stay green (17,028 minutes, 0 mismatched, peak 2,917).
