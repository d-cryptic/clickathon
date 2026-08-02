# WORKTREE_QUEUE — the prioritised work list, brief-ready

> **Summary:** One row per unit of work, ordered so the next worktree can be spawned without
> re-deciding anything. Each entry names the files it OWNS (so parallel worktrees cannot collide), its
> ADR number where one is needed (assign here, never let an agent pick — three agents once all chose
> 0009), and what "done" means. Sourced from the Codex cross-model audit
> [`codex-validation/001.md`](codex-validation/001.md), `checkpoint/1.md` §C5, and
> [`EXPLAINER.md`](EXPLAINER.md) §C.5. **Verify a claim before building on it** — the audit is a
> hypothesis about this repo until re-measured, exactly like any inherited number.

**Reserved ADR numbers:** 0009–0016 used (0015 claimed by a parallel worktree; 0016 = Q2, shipped).
**Next free: 0017.** Assign from this file. Q5/Q8 renumbered accordingly below.

---

## Currently claimed — 2026-08-01, 10 slots

Ownership is **exclusive**: an agent edits only the files in its row. Collisions between running
agents cost more than the work is worth. ADR numbers are **assigned here, centrally** — three
agents once all created ADR 0009 because their briefs said "next free number", and repairing it
touched ten files.

| # | Branch | Owns | ADR |
|---|---|---|---|
| ~~Q2~~ | ~~`fix/incremental-publisher-tiers`~~ | **MERGED** — all four tiers converge | 0016 |
| ~~Q12~~ | ~~`feat/benchmark-evidence-bundle`~~ | **MERGED** — 13 answers, bytes read, query ids | — |
| ~~Q4·Q7~~ | ~~`docs/scope-claims`~~ | **MERGED** cf8f1f6 — also converged dev with main (6 commits) | — |
| ~~Q3·Q5~~ | ~~`docs/validation-dossiers-grain`~~ | **MERGED** — dossiers 05 + 06 | none written |
| ~~Q13~~ | ~~`feat/clickstack-dashboards-sources`~~ | **MERGED** — 7 dashboards, 53 tiles verified signed-in | — |
| ~~Q18~~ | ~~`chore/unseen-day-rehearsal`~~ | **MERGED** — 10 defects found, incl. a runbook broken on macOS | — |
| ~~Q19~~ | ~~`docs/headline-assumption-audit`~~ | **MERGED** — 21 probes; minute membership worth −14.1% | — |
| Q24 | `docs/problem-space-bakeoff` | `docs/design-bakeoff.md` — adjudicate the 9 unmerged commits | — |
| Q25 | `docs/query-performance-audit` | `sql/60_projection.sql`, `evidence/query-performance.md` | 0021 |
| Q26 | `fix/hour-rollup-id-collision` | `sql/50_hour_agg.sql`, `tools/unseen-*.sh` | **0022** |
| Q27 | `docs/submission-artifact-audit` | `deck/checkpoint1/`, `docs/artifacts/` — claims on `main` predate 12 merges | — |
| ~~Q13-old~~ | ~~superseded~~ | `tools/clickstack-*.sh`, `docs/CLICKSTACK*.md`, `evidence/clickstack/` | — |
| ~~Q14~~ | ~~`feat/demo-rehearsal`~~ | **MERGED** — rehearsed live twice, 11 s machine time | — |
| ~~Q15~~ | ~~`fix/ci-and-coverage`~~ | **MERGED** — `make ci` green, coverage 58.7–95.7% | — |
| ~~Q16~~ | ~~`fix/target-resolution`~~ | **MERGED** + follow-up: `tools/ch` now reads `TARGET` from the env | 0018 |
| Q18 | `chore/unseen-day-rehearsal` | `docs/RUNBOOK_UNSEEN.md`, `tools/unseen-*.sh`, `evidence/unseen/` | — |
| Q20 | `docs/judge-entry-point` | `README.md`, `SUBMISSION.md`, `docs/VERIFIED.md` | — |
| Q21 | `chore/adr-0016-scale-remeasure` | `evidence/scale.txt`, `tools/scale-test.sh` — ADR 0016 re-engined a serving tier under the published figures | **0020** |
| Q22 | `chore/test-audit` | Go `*_test.go`, `docs/TESTS.md` — sabotage each test, keep the ones that fail | — |
| Q23 | `chore/post-merge-review` | `docs/codex-validation/003-*.md` — a different model reviews nine same-hour merges | — |
| Q8–Q11 | `docs/publisher-state-machine-safety` | `tools/publish*.sh`, `sql/12_publish.sql` — crash window, publisher lease, insert identity, retention bound | **0019** |
| Q19 | `docs/headline-assumption-audit` | `evidence/adversarial/`, **`doubts/07+`** ⚠ moved from 06 — the grain agent used 05 AND 06 | — |
| — | `feat/problem-space-research` | idle · 9 unmerged commits · **competing design, needs a human call** | — |

**Unblocked 2026-08-01.** Q8–Q11 were queued behind Q2 because they share `tools/publish.sh` and
`sql/12_publish.sql`. Q2 merged, so they are now claimed above — with the warning that ADR 0016
added two phases (`hours`, `users`) to the very state machine they harden. Q7 landed inside the
scope-claims pass. Q17 is closed: 2 of the 7 dangling links were real rot and are fixed; the other
5 live in `docs/upstream/`, a verbatim vendored copy whose `data/` links describe the upstream
layout and whose CSVs are gitignored here — both files now say so, and a future link scan should
skip that directory rather than "fix" it.

**ADR numbers in flight:** 0015 held by the unmerged `feat/problem-space-research`; 0016 publisher
tiers (**merged**); 0017 grain dossiers; 0018 target resolution; 0019 publisher safety.

## Tier 0 · Correctness, and it is invisible to our own gate

| # | Work | Owns | Done when |
|---|---|---|---|
| **Q1** | **`sonyliv observe` reports a green gate as FAILED.** Verified live: prints `reconcile pass=false max_abs_delta=0` while the gate says 17,028 minutes / 0 mismatched / PASS. `internal/pipelinehealth/reconcile.go` still parses the old five-column table; the gate now emits `ord` and `scope`, so it parses zero rows and correctly treats "no evidence" as failure. The unit fixture pins the old shape, so tests pass while the parser is broken. | `internal/pipelinehealth/`, its fixtures | `observe` reports `pass=true`; the fixture is regenerated from what `tools/reconcile.sh` writes **today**; a deliberately-failing gate still parses as failure |
| **Q2** | ✅ **DONE — ADR 0016**, branch `fix/incremental-publisher-tiers`. The publisher now re-derives touched hours (`hours` phase) and touched user-minute buckets (`users` phase); `cc_user_minute` became `ReplacingMergeTree(computed_at)` so a bucket is **replaced, not unioned** — retraction works and `mv_user_minute` is retired. `publish-test.sh` instantiates both tiers in both scratch DBs and compares them after growth, shrink, dimension change and a late straggler. | `sql/12_publish.sql`, `tools/publish.sh`, `tools/publish-test.sh`, `sql/45_user_concurrency.sql`, `sql/50_hour_agg.sql`, ADR **0016** | done when merged; evidence in `evidence/publish.txt` |
| **Q3** | **Minute-boundary semantics are self-confirming.** The expansion includes `toStartOfMinute(interval_end)`; half-open overlap would exclude it. 505 intervals across 493 sessions hit the case; the alternative moves 91 minutes, 302 viewer-minutes, and the peak 2,917 → 2,916. Both the model *and* `90_reconcile.sql` use the same convention, so a green gate **cannot** choose between them. | `doubts/05-*.md` (new) | a mentor dossier in the existing format: evidence + exact wording + decision table. **Do not change the model** — this is Q8, a definition question |

## Tier 1 · Claims we make that are not yet true

| # | Work | Owns | Done when |
|---|---|---|---|
| **Q4** | **Docs overstate ADR 0013.** `TODOS.md` marks continuous aggregates DONE; `ARCHITECTURE.md` says "Nothing is ever updated or rebuilt" while the finalizer schedules a `DELETE` prune per run; `WALKTHROUGH.md` says "byte-identical" without scoping it to interval/minute-delta; its summary contains both "published incrementally" **and** "batch-rebuilt". Every claim needs one scope and one current number. | `TODOS.md`, `WALKTHROUGH.md`, `docs/ARCHITECTURE.md` | no headline claim exceeds what `evidence/publish.txt` actually proves |
| **Q5** | **Dedup is NOT inert at filter grain.** `evidence/dedup.txt` proved inertness at the old 3-dimension headline. The model now carries 7. Re-measured: same totals and peak, but **6 interval dimension attributions change**, audio-language curves move for `hin`/`non`/`unk` across 18/15/26 minutes, and the `UNK` audio peak goes 183 → 184. Upstream step 3 is therefore unvalidated for dimensioned answers. | `evidence/dedup.txt`, ADR **0017** | the conclusion is scoped to the grain it holds at, and the filter-grain policy is decided and stated |
| **Q6** | **Normalisation is built, ADR'd, and absent from Cloud.** Verified: no `norm_*` UDF or `%norm%`/`%drift%` view exists in `sonyliv`. Now wired as stage 5/5 of `build-model.sh`, so the next rebuild creates it — but nothing creates it today, and the audit measured raw Hindi peak 1,774 → 2,196 normalised, not the 1,791 → 2,213 pair the docs carry. | `sql/15_normalise.sql`, ADR 0011 amendment | applied to `sonyliv` (**operator call — schema change**), docs carry the current pair |
| **Q7** | **`checkpoint/1.md` needs a "current status" pointer.** It is deliberately historical and correctly said publication was batch at that moment. Without a forward pointer a reader mixes it with post-checkpoint claims. | `checkpoint/1.md` header only | one line at the top pointing at `WALKTHROUGH.md`; the body stays frozen |

## Tier 2 · Robustness the audit found by inspection

These are **code-inspection findings, not reproduced incidents** — reproduce before fixing.

| # | Work | Owns | Done when |
|---|---|---|---|
| **Q8** | **Publisher crash window.** `publish.sh` writes `cc_publish_batch`, then `cc_publish_consumed`, then appends `claimed` to `cc_publish_runs`. A failure between steps 2 and 3 leaves the dirty markings consumed with no in-flight run — the batch is orphaned and silently skipped. Phase markers protect everything *after* `claimed`. | `tools/publish.sh`, `sql/12_publish.sql`, ADR **0018** | crash injected at every phase, recovery proven |
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
| **Q16** | **Local target is misconfigured.** Go and several tools read `CH_DATABASE` (Cloud) for local work, so local verify 404s; `tools/ch` uses the server default instead. Local `cc_minute_stateless` is `uniq` where Cloud is `uniqExact`. | `internal/config/`, `tools/ch` | one command targets one database regardless of implementation  **Sharpened 2026-08-01 by reproduction:** `tools/ch` does not read `TARGET` **at all** — it selects Cloud from a positional `-c` flag. So `TARGET=cloud tools/ch "…"` runs against **local**, silently, with a zero exit path that looks like success. It resolved a query against a leftover scratch database (`tie0014`) and, when qualified, returned `Database sonyliv does not exist` — which reads as *the graded database is gone*. It was not; the query was on the wrong server. Any tool or agent that follows the repo-wide `TARGET=` convention here gets the wrong host with no warning. |
| **Q17** | **7 broken Markdown links; 4 files violate the 7-line-summary rule.** | the offending files | link scan clean |

---

## The v1-hardening wave — 2026-08-02, 10 slots on judge feedback

Spawned after the judges said **more filter columns will appear** and **the unseen data will be more
real and cruel**, and after re-reading `docs/upstream/` line by line.

| # | Branch | Answers which spec line | ADR |
|---|---|---|---|
| T1 | `chore/t1-new-filter-columns` | `dataset_details.md:43` *"should work even if the number of dimensions increases"* — today a new column **loads and is silently dropped**, a missing one silently becomes `''` (both measured) | **0024** |
| T2 | `chore/t2-a-generator-for` | *"validate against representative OTT viewing scenarios"* — a cruel-data generator with per-hazard knobs, each file carrying its designed truth | — |
| T3 | `chore/t3-runtime-preprocessing` | operator: *"preprocessing at runtime"* — reject vs quarantine vs normalise, biased toward quarantine because a discarded row is invisible to every check we have | **0025** |
| T4 | `chore/t4-turn-the-edge-case` | Codex 003 §11 register → executable fixtures, expected values derived **by hand**, each sabotage-checked | — |
| T5 | `chore/t5-query-robustness` | *"queries should handle those use cases"* — 13 shapes × hostile conditions; the invariant grid | — |
| T6 | `chore/t6-a-reference-interpreter` | Codex 003 §13.2 — property tests vs an independent interpreter; **batch invariance** is the one nothing else tests | — |
| T7 | `chore/t7-the-replay-demo` | `PROBLEM_STATEMENT.md:79` *"the concurrency curve builds in near real time"* — we have never shown it building | — |
| T8 | `chore/t8-the-spec-names` | `dataset_details.md:21` names `AppBackgrounded`/`AppForegrounded`; **29,021 exist and our derivation references them 0 times** | — |
| T9 | `chore/t9-a-source-contract-gate` | bake-off cherry-pick #1 — assert what is true about a file **before** we trust it | **0026** |

**ADR ledger:** 0019 publisher safety (in flight) · 0020–0023 merged · 0024 T1 · 0025 T3 · 0026 T9.

**Closed by me directly, not spawned:** the organiser's four *"design decisions to confirm"*
([docs/DESIGN_DECISIONS.md](DESIGN_DECISIONS.md)) — three were decided but scattered; **event
lateness tolerance is genuinely undecided** and is a mentor question, not something to invent.

## Q26 · The sentinel collision is latent, not live — and the unseen day is exactly when it fires

The unseen-day rehearsal (R9) demonstrated that a **real** `content_id = -1` session is served as
peak 2 against a true peak of 1, because the cube's all-content rollup uses `-1` as its sentinel and
the two silently merge. Every cube query for that content is then wrong.

**Checked against the graded data before prioritising it:** `ev_raw` contains **0** events with
`content_id = -1` and **0** with `-987654399`. So nothing we serve today is wrong. This is a trap
that fires **only if the unseen day contains one** — which is precisely why the rehearsal
manufactured one, and precisely the scenario we get no chance to debug.

Fix so a real id can never collide with a rollup marker: a separate `is_rollup` flag, a value outside
the id domain, or a documented guarantee that negative ids are reserved. Whichever, the unseen-day
loader should **assert** the invariant rather than trust it.

## Q34/Q35 · The two real model disagreements the property suite found — verified live, severity measured

`tools/reference_interpreter.py` (T6) compared 400 random sessions against a spec-derived Python
implementation and found two genuine disagreements. **Both verified by the orchestrator against the
graded database**, and both sized before being prioritised — because an unsized finding gets either
ignored or over-reacted to.

### Q34 · User concurrency can exceed session concurrency — **verified live, off-by-one, headline safe**

The invariant is unconditional: one user may hold several sessions, so users ≤ sessions at the same
minute and grain, always. It does not hold.

```
 violating cells on sonyliv     82        ← CORRECTED, see below
 worst excess                   +1
 cells with sessions=0, users>0 63
 HEADLINE user peak 2,844  vs  session peak 2,917   ✓ still correct
```

⚠ **The orchestrator first published 28 and 0. Both were wrong.** The query joined `cc_user_minute`
to `cc_minute_delta` on `minute` — but the delta table only carries rows at **change points**, so an
inner join silently compares a dense table to a sparse one and only sees minutes where the level
moved. Codex audit 005 caught it. The corrected figures are 82 cells with 63 at zero sessions.

The severity verdict is unchanged — worst excess is still +1 and no total moves — but the sizing was
wrong, and a wrong number offered as reassurance is worse than no number.

Cause per T6: ADR 0012's first-wins dimension merge and ADR 0016's per-interval expansion disagree
about attribution, so a user lands in a `(minute, dims)` bucket whose session deltas went elsewhere.
**Severity: low.** It is off-by-one on per-combination cells and never touches a total. Worth fixing
because an invariant that "mostly holds" is not an invariant — a judge testing it will find it — but
it changes no number we submit.

### Q35 · Zero-length segments erase point activity — **worth +10 on the peak**

A run consisting of a single event produces a zero-length segment, dropped **before** `TAIL_S` is
applied, so it earns no watch time at all. T6 measured **182 such runs**; keeping them moves the peak
**2,917 → 2,927** and adds **5.0 h**. Shrunk to a one-event reproduction.

**The gate cannot see it** — `sql/90_reconcile.sql` carries the same filter, so truth and serving
agree while both discard the same activity. Same structural blindness as `doubts/05`–`12`.

**This is a semantics question, not obviously a bug.** Does a viewer who generated exactly one event
count as watching for one cadence, or not at all? Our answer is currently "not at all", by accident
rather than decision. It should become a decision — and it interacts with `doubts/07`, which measured
tail credit at explicit stops.

**Neither is fixed.** `sql/30_build_intervals.sql` and `sql/90_reconcile.sql` are a shared-spec pair;
changing one without the other makes the gate agree with a bug. That is a wave-2-style promotion, not
a patch.

> **✅ BOTH DONE — [ADR 0031](adr/0031-point-activity-user-attribution-and-the-densify-recipe.md),
> 2026-08-02, branch `chore/y2-the-three-defects`.** Q35 is now the constant `POINT_ACTIVITY_COUNTS`,
> shared by model and gate, **shipped at 0 (peak 2,917) and recommended at 1 (peak 2,927)** — the flip
> is an **operator decision** and is the only change in that ADR that moves a submitted number.
> Q34 is fixed by expanding merged runs (**82 → 1** violating cells; the last one is the data, not the
> model — 9 sessions carry two `user_id`s). The "+5.0 h" above is superseded: our own pipeline measures
> **+4.617 h / +16,620 s**; Codex's 18,127 s came from the independent spec interpreter, which agrees
> exactly on the concurrency curve and differs only in interval packing. U3-F1 fixed in the same commit.

## 🔴 Q36–Q39 · Open from the two Codex audits (005 dev-audit, 006 unseen rehearsal)

### Q36 · Two more graded-write paths, both unguarded — **P0**

The `REBUILD_GRADED` / `APPLY_GRADED_DESTRUCTIVE` guards cover `build-model.sh` and `apply-sql.sh`'s
DROP/TRUNCATE. Codex 005 found they do **not** cover:

- **`load.sh --replace`** against the graded database.
- **Direct `apply-sql.sh` on a file whose statements are INSERT/CREATE** — deliberately ungated so
  views and UDFs can be applied, which also means a file that *writes rows* passes freely.

Same family as the two incidents. The guard was never meant to be the only line, and here it is not
even present.

### Q37 · The contract load and the real runner disagree about a valid file — **unseen-day risk**

Codex 006: a valid CSV with an **embedded newline**, and a valid **new filter column**, are both
accepted by the contract-gate load and then **rejected by the real runner**. So a file can pass the
check that says "this file is fine" and fail the run. On a day with one attempt, a green pre-flight
followed by a failed run is close to the worst sequence available.

### Q38 · The runbook's timings understate by ~1.5× — **fix the number, not the code**

Measured fresh: **70/67/71 s** for 6.9k/30k/850k builds, and **90/79/97 s** for the actual
contract-first paths. The runbook quotes 47/54/58 s, which predates the contract step. Codex 006's
verdict is the sentence to keep: *"At 3am, a correct submission is not guaranteed."*

### Q39 · Two claims that do not hold, from Codex 005

- **The decline-alert classifier's "semantic anchors" do not hold.** The merge message asserted
  `hb_per_session < 1.0` sits below ADR 0007's measured 0.756/min paused rate and therefore cannot be
  viewer behaviour. Codex checked and disagrees. **I repeated that claim in a merge message without
  verifying it** — the pattern this repo keeps re-learning.
- **`docs/BUSINESS_RULES.md` contains stale and arithmetically false statements**, despite its CPM
  calculation being correct. A commercial reader checking one figure is exactly the audience that
  will find them.

## 🔴 Q33 · `build-model.sh` and `reconcile.sh` still carry bug 11 — found INDEPENDENTLY by two agents

Two agents in different lanes hit the same defect within an hour, which is why this is a queue item
rather than a footnote in one worksheet.

Both scripts do `set -a && . ./.env` **after** the caller's environment is read, so `.env`
**overwrites** an exported `CH_DATABASE`. Consequence: `CH_DATABASE=scratch TARGET=cloud
tools/build-model.sh` resolves to **`sonyliv`** — the graded database — and only the new
`REBUILD_GRADED` guard stops it.

- **T3** could not build a scratch model at all and had to replay all six stages by hand with
  `apply-sql.sh --database`.
- **T1** asked for `adr0024_drift` and the script **TRUNCATEd `default.session_intervals`** before
  dying on a schema mismatch. Local-only damage — and the same table Q30 describes, so the two
  findings are one story.

**The fix already exists** at the top of `tools/ch`, `tools/apply-sql.sh` and `tools/load.sh`:
capture the environment's view *before* sourcing `.env`, so the environment wins. It needs copying
into `build-model.sh` and `reconcile.sh`, plus a sweep for any other `set -a && . ./.env`.

**Severity, stated honestly:** the guard means this can no longer reach the graded database
unauthorised, so it is not a live correctness risk. It *is* a productivity and safety trap — a
scratch build via env override is currently impossible, and the guard is the only thing between that
mistake and `sonyliv`. Belt and braces are both required here; the guard was never meant to be the
only line.

## Q30 · Local `default.session_intervals` is on a pre-ADR-0012 schema — **operator call**

Found 2026-08-01 while testing the new write guards: `default.session_intervals` has **no
`build_version` column**, so it predates ADR 0012 and `tools/build-model.sh` cannot rebuild it
locally (`Code: 16 · No such column build_version`). Any "verify it locally first" step is therefore
running against a schema Cloud has not had for hours.

The table's contents were stale for the same reason, and testing the guard truncated it — no loss,
but it is now empty as well as mis-shaped. `ev_raw` is intact (905,558 rows) and every scratch
database (`adv_q19`, `scale_x100`, `scale_real`, `tie0014`, `csv_audit`) is untouched.

**Not fixed, deliberately**: repairing it means dropping and recreating a table, and the standing
instruction is to ask before touching schema. The fix is a local `DROP TABLE default.session_intervals`
followed by `tools/apply-sql.sh sql/00_schema.sql` and a local rebuild. Related to Q16 (ADR 0018),
which unified *which* database each target resolves to but not *what shape* the local one is in.

## Q32 · Two LIVE views can return a nondeterministic peak minute — 70 of 98 hours are exposed

The graded-database inventory found five windows views predating [ADR 0014](adr/0014-peak-minute-ties-resolve-to-the-earliest-minute.md);
I confirmed **2 still contain a bare `argMax(minute, …)`**. ADR 0014 exists because a tied peak must
resolve to the **earliest** minute, deterministically. These views never got the fix.

**Measured, so the severity is not guessed:**

| | |
|---|---|
| Global peak **2,917** | occurs at exactly **one** minute (10:56) — **the headline answer is safe** |
| Hour-grain peaks | **70 of 98 hours have a tied peak minute** — every one is a coin flip in these views |

So a day-grain "what was the peak" answer is unaffected, and an hour-grain "**when** did it peak"
answer can differ between two runs of the same query on unchanged data. Peak-minute is a plausible
benchmark output, and a judge re-running a query and getting a different answer is the worst kind of
failure — it looks like the pipeline is unstable.

**This is the same defect the unseen-day rehearsal found and fixed in the runbook (finding R5).**
It was fixed there and missed here, because nobody had looked at what the *database* actually holds
versus what the repo's SQL says. That gap is exactly why the inventory task existed.

Fix: apply ADR 0014's tie-break to the five views. `CREATE OR REPLACE VIEW` is **not** gated by the
new `apply-sql.sh` guard (only DROP/TRUNCATE are), so this is a low-risk forward fix rather than part
of the migration debt below — but it still touches the graded service, so **operator call**.

## 🔴 THE MIGRATION DEBT — three schema changes now live in code but not on the graded database

Each was correct to defer (schema changes on a graded service are an operator call). Together they
are a pending migration nobody has scheduled, and the risk is **each one is individually harmless
while the set is not**: they all apply in one rebuild, and that rebuild has never been run.

| ADR | Code says | Graded `sonyliv` has | Verified |
|---|---|---|---|
| **0016** | `cc_user_minute` is `ReplacingMergeTree(computed_at)`, `mv_user_minute` retired | `SharedAggregatingMergeTree`, **`mv_user_minute` still present** | read-only, 2026-08-01 |
| **0021** | `proj_by_session` is a documented, database-agnostic projection | projection **is live** (applied 10:12, undocumented until found) | `system.mutations` |
| **0022** | `cc_hour_agg` carries `cube_level` in the key | **no `cube_level` column** | `system.columns` |

**What is safe right now.** Every graded answer is still correct: the hour peak reads 2,917 through
the sentinel path, the user tier reads 2,844, and the gate passes on 17,028 minutes. ADR 0022's
collision cannot fire because `ev_raw` has **0** rows with `content_id = -1`. The batch rebuild
masks ADR 0016's retraction gap by truncating first.

**What is not safe.** Running `tools/publish.sh` against `sonyliv` — its `users` phase writes
replace-semantics rows into a set-union table. Its cursor is at epoch; **keep it there.**

**The whole migration is one authorised rebuild**: `build-model.sh` step 2/6 already detects and
migrates the `cc_user_minute` engine, and re-applying `sql/50_hour_agg.sql` brings `cube_level`.
So `REBUILD_GRADED=yes TARGET=cloud tools/build-model.sh` from a clean tree does all three at once,
followed by `/reconcile`. **Operator call** — [CLAUDE.local.md](../CLAUDE.local.md) says ask before
touching schema, and the answer may legitimately be "not before the deadline".

The thing to avoid is drifting further: every additional deferred change makes that one rebuild
larger and less rehearsed. If the answer is "don't migrate", say so explicitly and stop shipping
schema changes that assume it.

## 🔴 The graded database is still on PRE-ADR-0016 shapes — do not run the publisher against it

Verified read-only 2026-08-01, immediately after ADR 0016 merged:

```
 mv_user_minute      STILL EXISTS on sonyliv   (ADR 0016 retired it)
 cc_user_minute      SharedAggregatingMergeTree (ADR 0016 makes it ReplacingMergeTree(computed_at))
```

**This is expected, not a defect.** ADR 0016 says in its own summary: *"nothing applied to
`sonyliv`."* The code and the proof are in the repo; the graded database was deliberately left alone
because applying a schema change to it is an operator decision.

**But two things follow, and both are traps:**

1. **Running `tools/publish.sh` against `sonyliv` right now would meet a table whose engine does not
   match what the code expects.** The publisher's `users` phase writes replace-semantics rows into
   what is still a set-union table. Its cursor is at epoch and it has never run there — **keep it
   that way** until the migration happens.
2. **Every claim that "the publisher owns all four tiers" describes the CODE, not the graded
   service.** True of the repo, not yet of what we are scored on. Docs must not blur the two — this
   is the same overstatement class that Q4 spent a whole task correcting.

The user tier currently reads the correct **2,844** because `tools/build-model.sh` TRUNCATEs
`cc_user_minute` before every rebuild, so the set-union retraction bug has no opportunity to
accumulate. That is a rebuild masking a latent defect, not the defect being absent.

**The migration path already exists**: `build-model.sh` step 2/6 detects a non-`ReplacingMergeTree`
`cc_user_minute`, drops it with `mv_user_minute`, and lets `sql/45_user_concurrency.sql` recreate it.
So the next **authorised** graded rebuild (`REBUILD_GRADED=yes`) migrates it. That is an operator
call — see [CLAUDE.local.md](../CLAUDE.local.md): ask before touching the schema.

## 🔴 The spawn defect that caused a production incident

`sc worktree create` bases a new worktree on **`main`**, NOT on the target branch, even after
`sc worktree set-target-branch dev`. Verified four times: every worktree spawned on 2026-08-01
forked from `542d80d` regardless.

**What it cost.** A worktree forked from `main` carries `main`'s `sql/`, which predates the ADR 0009
merge. That agent ran a model build against Cloud and left the **graded database serving two model
generations** — minute tier 2,887 with 1,949.331 hours, hour tier 2,917 — for roughly two hours,
until an external audit caught it. `query_log` shows the good build at 13:59 (122,015 → 28,073)
overwritten at 16:16 (121,492 → 28,139).

**Every brief must therefore contain both of these, verbatim:**

```
STEP ZERO, before reading anything else:
    git fetch origin && git merge origin/dev
Your worktree is forked from `main` and is missing everything on dev.

NEVER run `make model`, `tools/build-model.sh`, or ANY write against TARGET=cloud or
database `sonyliv`. `tools/reconcile.sh` is read-only and is fine. If you need to build
a model, create your OWN scratch database — sql/70_truncation_test.sql shows the pattern.
```

The guard is the load-bearing half: the stale base is an inconvenience, writing to the graded
database with stale SQL is an incident.

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
