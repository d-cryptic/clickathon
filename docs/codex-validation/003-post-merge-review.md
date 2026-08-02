# Codex Validation 003 — Post-merge adversarial review of the nine unreviewed merges

> **Summary:** Reviewed `dev` at `4dabfa3` on 2026-08-01 — the nine tasks merged in one hour with orchestrator-only review — through correctness, security/ops, and AI-smell personas, with live read-only verification against `sonyliv`.
> ADR 0016's design is sound where it was doubted: the publisher's scope is a provable superset, retraction-by-empty-state works, the harness compares all four tiers against a control rebuild, and live Cloud is back on ONE coherent generation (minute 2,917 = hour 2,917, user 2,844) — codex 002's split-tier P0 is healed.
> Four P0s remain: the submitted unseen-day peak-minute still uses the bare `argMax` ADR 0014 proved nondeterministic; `build-model.sh`/`apply-sql.sh` can still truncate or DDL the graded database with zero guard (the morning-incident mechanism); WALKTHROUGH/ARCHITECTURE still assert the publisher "has zero references to `cc_hour_agg`/`cc_user_minute`" — false since the Q2 merge and contradicted lines away in the same files; and two "verified" claims (window and content reconciles) cite evidence that does not exist in the tree.
> The merge-conflict combinations produced exactly the predicted failure: statements neither parent made, plus six stale "ADR 0016 pre-assigned" pointers that set up the next ADR-number collision (`doubts/06` reserves an ADR that shipped today as something else).
> "No concurrency serves as no row" holds only at the user/hour/day grains ADR 0016 touched — the minute-grain views have no zero filter, the shipped DIMENSION-FLIP test creates the divergence, and the harness compares exactly the grains where it cannot show.
> The new Go tests are genuine (no stub-passers; the reconcile-parser fixture provably matches the real emitter), the demo is read-only and rehearsed, and the benchmark bundle satisfies every codex 001 §4.10 demand with no signs of fabrication.

## 1. Verdict

The nine merges are substantially better than their review coverage deserved: every piece of
*shipped machinery* audited here (publisher phases, convergence harness, reconcile parser + tests,
demo runner, benchmark capture) held up under adversarial reading, and the live graded database is
in the healthiest state any validation has observed. The defects are concentrated in three places:
**one unpatched consumer of a known bug** (the submitted peak-minute), **unguarded write paths to
the graded database**, and **documentation that the merge conflicts recombined into claims neither
side made**. The last category is not cosmetic: the same contradiction family (TODOS says DONE,
WALKTHROUGH says PARTIAL, ARCHITECTURE contradicts itself) already mis-routes agents — one open
queue item (Q6) currently directs a schema change at the graded database to fix a problem TODOS
says was solved this afternoon.

| Merge (in order) | Verdict |
|---|---|
| Reconcile-parser fix (`f011818` tests, parser earlier) | **Sound.** Fixture provably matches the real emitter; regression pinned both directions. Residual: fixture refresh is manual (§6.1). |
| ADR 0016 — publisher owns user + hour/day tiers (`54cf44c`) | **Code sound, proven; docs it obsoleted not updated** (§3, §4.3). One serving-contract gap at minute grain (§4.5). |
| ADR 0018 + `tools/ch` TARGET (`6638d8b`, `f5467e3`) | **True for `tools/ch` and Go; overstated as "every layer"** (§4.2). Write-guard gap is P0 (§4.1.2). |
| `make ci` green + ~1,300 Go test lines (`f011818`) | **Genuine.** Green with the pinned toolchain, refuses loudly otherwise. Coverage claims verified (§6.1). |
| Demo harness (`4323b37`) | **Read-only confirmed, rehearsed, numbers match.** Sanity beat blind to the split-generation failure it exists for (§6.2). |
| Benchmark evidence bundle (`eb3edfa`) | **Complete per codex 001 §4.10; internally consistent to the hash level** (§6.3). Checksum is a copied pin, not a run-time hash. |
| Doubts dossiers 05 + 06 (`4ec9b28`) | **Arithmetic sound, decision tables complete.** 05 ignores codex 002's conflicting count; 06 reserves a consumed ADR number (§4.4). |
| Docs scoping pass (Q4 + Q7, `3f5bbdc`) | **Partial.** Deck fixed; EXPLAINER §C.6/D.1/E.2/E.3 and the interval-math skill still carry the retracted claims (§5). |
| Queue/link hygiene (`d4f8306`, `4dabfa3`) | **Q19 dossier renumbering clean; the queue's own ADR ledger is triply inconsistent** (§4.4). |

## 2. Snapshot, scope, and method

- Branch/commit reviewed: `dev` at `4dabfa3`, merged into worktree `sc-flux-fermion-3691`
- Live Cloud: ClickHouse `26.2.1.525`, database `sonyliv` — **read-only throughout**; every
  query issued was a `SELECT` against system tables or serving views
- Prior audits assumed as baseline: [`001.md`](001.md), [`002.md`](002.md)
- Review personas: correctness (interval/tier algebra, engine semantics), security/ops (write
  paths to the graded database, target resolution), AI-smells (numbers with no surviving evidence,
  claims recombined by merges, fixture drift)
- Five parallel review streams (claims-vs-evidence, conflict archaeology, Go-test audit,
  ADR 0018/demo/bench, unowned-claims) plus a manual deep-dive on ADR 0016, the highest-risk change

Per the review brief: this document reports; it fixes nothing. Findings carry a reproduction or
the reason one was not possible. Confirmations state how they were checked.

## 3. ADR 0016 deep review — the questions the author could not ask

This was reviewed by deriving the correctness argument independently before reading the ADR's own,
then checking the code and the live database against both.

### 3.1 Confirmed: the scope is a provable superset (the undercount does not exist)

The dangerous failure mode would be branch 1 of the canonical user INSERT missing an *untouched*
long interval that covers a scoped minute — replacement would then silently drop that user from
the recomputed bucket. It cannot happen. The minute scope is
`[toStartOfMinute(LO), toStartOfMinute(HI) + 240 s]` (`tools/publish.sh:416`, `+241` range end),
so every scoped minute lies in `[LO − 60 s, HI + 240 s]`. The interval prefilter
(`tools/publish.sh:419`) keeps every interval with
`interval_end ≥ LO − 300 s AND interval_start ≤ HI + 300 s`. An excluded interval either ends
before `LO − 300 s` (its last covered minute `toStartOfMinute(interval_end) < LO − 300 < LO − 60`)
or starts after `HI + 300 s` (its first covered minute `> HI + 240`). Neither can cover a scoped
minute. The 300 s margin strictly dominates the 60 s minute-floor slop on both sides. The hours
phase has the analogous property via hour-clipping (ADR 0003): the `+7201`/2-hour margin covers
the close delta landing one minute after `interval_end ≤ hi + TAIL_S`.

### 3.2 Confirmed: two writers, FINAL, and crash-resume

- **Two writers at the same `computed_at`**: `ReplacingMergeTree` keeps an arbitrary row among
  equal versions, so a millisecond tie between two concurrent publishers picks a nondeterministic
  winner. This is real but is the documented single-publisher assumption (audit 001 §4.4, queue
  Q8–Q11 — verified still tracked). One honest nuance the ADR's "neither widens nor narrows"
  wording misses: the two-writer failure *mode* changed — the retired set union could only inflate
  monotonically, while replacement lets a stale full re-derivation **erase** a correct newer
  bucket outright. Same open invariant, different blast shape. No reproduction attempted: it
  requires two concurrent publishers, which the design already forbids.
- **FINAL under concurrent merges** behaves as claimed by engine contract, and every reader that
  must collapse versions does read FINAL (`sql/45_user_concurrency.sql:198,213`;
  `sql/50_hour_agg.sql:274,289,339,354`; `sql/85_windows.sql:447,516`).
- **Crash-resume for the new phases is genuinely idempotent.** A death after the `hours` INSERT
  but before its `mark` resumes at phase `emitted`; the replayed INSERT is dropped by
  `insert_deduplication_token=${run_id}:hours` (`tools/publish.sh:394,425`), the phase marker is
  then written, and data that arrived in between is claimed by the *next* run via its own
  unconsumed markings. The pre-existing consumed-before-claimed window (001 §4.3) is unchanged.

### 3.3 Confirmed: the evidence and the live database

- `evidence/publish.txt` matches ADR 0016's measured table line-by-line: all 16 convergence
  checks at 0 differing across bootstrap, late-5, full stream, straggler, SHRINK, DIMENSION FLIP,
  and 200 forced republications; user peak 2,844 and hour peak 2,917 identical by both routes at
  every stage; SHRINK moved `2026-07-26 11:30` from 197/191 to 196/190 as stated.
- The compare method is the right one: signed sums at full dimension grain for the delta table and
  intervals, `FULL OUTER JOIN` on the serving views for the user/hour/day tiers — absence-vs-zero
  and stale rows both register at the compared grains.
- Live `sonyliv`, read directly: `cc_user_minute` is still `SharedAggregatingMergeTree` with
  `mv_user_minute` present (pre-ADR-0016 shapes — "nothing applied to `sonyliv`" is TRUE);
  `session_intervals` carries exactly **one** `build_version` (1785602353); minute-tier max
  concurrent = **2,917**, hour-tier peak = **2,917**, user peak = **2,844**, 30,323 intervals,
  91,692 user-minute buckets; the publisher tables exist with `v_cc_publish_lag` at epoch-zero
  cursors and 0 runs — installed and inert, exactly as documented. **Codex 002 §2.2's
  split-generation P0 (2,887 minute vs 2,917 hour) is healed in production.**
- `tools/build-model.sh:66-84` implements the engine-detect → `DROP` → re-apply migration and the
  explicit stage-2 population exactly as the ADR describes, plus the user-tier gate.

### 3.4 Findings against ADR 0016

The findings are numbered into the master list in §4; the ADR-specific ones are 4.5 (minute-grain
zero rows), 4.6 (the SummingMergeTree mislabel that the tombstone guarantee silently depends on),
4.7 (the untested migration branch whose first execution will be against `sonyliv`), and the
tombstone-accumulation cost (documented honestly in the ADR; confirmed bounded — branch 2 rewrites
every in-scope tombstone key each run until a rebuild's TRUNCATE clears them; storage, not
correctness).

## 4. Critical findings

Ranked by consequence: wrong served number → graded-database risk → misrouted operator/agent →
contract inconsistency.

### 4.1 P0

**4.1.1 — The submitted unseen-day peak-minute is still produced by the bug ADR 0014 measured.**
`tools/unseen-run.sh:319` computes the submission's peak minute with a bare
`argMax(minute, concurrent)`, and `tools/unseen-run.sh:314` and `sql/90_reconcile.sql:216` carry
the same shape — the exact form ADR 0014 measured returning **16 distinct answers in 20 runs**
under ties, with the earliest-wins tuple defined and shipped everywhere else
(`sql/50_hour_agg.sql:226`). Ties at the peak are the common case (49% of hour rows at the
all-dims level, per `sql/50_hour_agg.sql:52-57`; 5 of 7 known days tie at day grain). The only
tracking is prose in `docs/RUNBOOK_UNSEEN.md:255-258`; no TODOS item, no queue row, no test.
*Reproduction:* not run (it requires executing the unseen runbook); the defect is established by
ADR 0014's own committed measurement plus the unpatched call sites. **If the unseen day's peak
ties, the submitted minute is a coin flip.** This is the highest-consequence finding in this
review.

**4.1.2 — The graded-database write guard exists on one write path out of four.**
`tools/publish.sh:80-83` refuses `sonyliv` without `PUBLISH_ALLOW_PROD=1` (strong).
`tools/load.sh:218-243` has a generic refuse-if-nonempty, but `--replace` TRUNCATEs with only a
banner. **`tools/build-model.sh` has no guard at all**: `TARGET=cloud tools/build-model.sh`
truncates `session_intervals`, `cc_user_minute`, `cc_minute_delta`, and `cc_hour_agg` on the
graded database (lines 62, 82, 87, 92) and can `DROP TABLE cc_user_minute` (line 77) — and a
*partial* failure mid-script recreates exactly the two-generation split its own header describes
(lines 26-31). **`tools/apply-sql.sh` applies arbitrary DDL to `.env`'s `CH_DATABASE=sonyliv`**
with only an existence check (line 150), and `tools/clickstack-cloud.sh:48,62` auto-runs
`apply-sql.sh sql/87_viz.sql` against a **hardcoded `sonyliv` fallback** as a side effect of
provisioning dashboards. The morning incident — the very event this review covers — used this
mechanism, and it remains one unguarded command away. The review brief's own prohibition had to
name these scripts; the repo does not enforce it. *Reproduction:* not run, for the obvious reason;
established by static read of every write statement in the four scripts.

**4.1.3 — The publisher-scope claims are merge artifacts that contradict the code, the queue, and
themselves.** Three independent streams converged on this. Current text asserts the pre-ADR-0016
scope: `WALKTHROUGH.md:10` ("no path for the hour/user tiers anywhere"), `WALKTHROUGH.md:66`
("maintains intervals+deltas only" — contradicted by line 71 five rows later),
`WALKTHROUGH.md:191` (README step 4 "**PARTIAL** … zero references to
`cc_hour_agg`/`cc_user_minute`", citing a queue row that says "MERGED — all four tiers converge"),
`docs/ARCHITECTURE.md:5-6` and `:70-74` ("contain **zero** references…") — the latter immediately
*after* the paragraph at lines 62-67 that correctly describes the `hours`/`users` phases. Ground
truth: `tools/publish.sh:372-430`, `sql/12_publish.sql:190-191`, `evidence/publish.txt`,
`TODOS.md:19` ("DONE for all four tiers"). Merge archaeology shows each false statement was true
on exactly one parent (`de23258` vs `147fd67`); the combination is a claim neither parent made.
Consequence: a grader under-scores deliverable step 4; the already-claimed Q8-Q11 agent hardens
the wrong state machine. `checklist.md:104-105` and `V0_CHECKLIST.md:148` carry the same wording.

**4.1.4 — Two "verified" correctness claims cite evidence that does not exist in the tree.**
`WALKTHROUGH.md:159` claims rolling/tumbling windows verified "vs brute-force self-join, 0
mismatches" — no evidence file mentions windows, no tool runs the comparison, and the one recorded
run (`docs/EXPLAINER.md:854`, commit `4a89399`) predates both ADR 0009 (model change) and ADR 0014
(rewrote `sql/85_windows.sql`). `WALKTHROUGH.md:158` claims a content hour-peak reconcile with "0
mismatches over 6,764 rows" — the number **appears nowhere in the repository** outside the claim;
the reconcile SQL sits commented-out in `sql/50_hour_agg.sql:361-425`, and the only content
evidence file (`evidence/reconcile-content-views.txt`) is from the pre-ADR-0009 generation (peak
2,887). Both sit in a table headed "Everything here was run, not reasoned about." Time-window
trends and content filters are scored deliverables. *Reproduction of the absence:*
`grep -rn "6,764\|6764" evidence/ docs/` returns only the claim.

### 4.2 P1 — target resolution ("one target, one database on every layer" is one-and-a-half layers)

- TARGET validation exists in exactly one layer: `tools/ch:42-45` dies on unknown values; Go's
  `TargetFromEnv` (`internal/config/config.go:170-175`) silently maps any non-"cloud" string —
  including typos — to local, case-insensitively; `apply-sql.sh`/`load.sh`/`publish.sh` do
  `[ "$TARGET" = cloud ]` else local. **`TARGET=Cloud` gets three different answers across
  layers**: dies in `tools/ch`, is cloud in Go, is local in the shell tools — the exact divergence
  class ADR 0018 exists to kill. `TARGET=Cloud tools/apply-sql.sh sql/20_views.sql` silently
  applies DDL locally while the operator believes Cloud was updated.
- `tools/publish.sh:34` defaults `TARGET=cloud` while every other tool defaults local — the ADR's
  own "odd one out" complaint, reintroduced.
- `tools/bench.sh:27` and `tools/reconcile.sh:27` read `CH_DATABASE` *after* sourcing `.env` with
  no prior environment capture (rule-3 violation — the same bug-11 class `tools/ch` fixed), and
  `bench.sh` ignores `TARGET` entirely: `TARGET=local tools/bench.sh` benches Cloud (read-only, so
  bounded). `tools/clickstack-cloud.sh:48` and `tools/clickstack-sources.sh:74` fall back to a
  hardcoded `sonyliv` — the pattern the ADR bans by name.
- `evidence/target-resolution.txt` is real and internally consistent but covers only `tools/ch`
  and Go `verify`; the f5467e3 "rejects a typo" claim has no captured rejection in evidence, and
  the ADR's "every layer" wording is asserted, not evidenced.
- Cosmetic: ADR 0018 numbers two rules "4".

### 4.3 P1 — the ADR-number ledger is set up for the next collision

- `doubts/06-dedup-at-filter-grain.md:12` (and its decision table) reserves **ADR 0016** for the
  dedup policy — consumed today by the publisher-tiers ADR. `docs/WORKTREE_QUEUE.md:62` reassigned
  the policy to 0017, but `WALKTHROUGH.md:160,207`, `checklist.md:136`, `V0_CHECKLIST.md:39`, and
  `doubts/README.md:19` still say "ADR 0016 pre-assigned". An agent recording the dedup decision
  from the dossier writes into the wrong ADR — the exact triple-0009 failure the queue file exists
  to prevent.
- `docs/ARCHITECTURE.md:73` says Q2 shipped as "ADR 0015, pre-assigned" (it shipped as 0016; 0015
  is held by an unmerged worktree). `docs/WORKTREE_QUEUE.md` disagrees with itself three ways:
  line 11-12 "Next free: 0017" vs line 46-47 holding 0017/0018/0019 in flight (0018 already exists
  on disk) vs line 72 assigning Q8 "ADR 0018" while line 34 says 0019.

### 4.4 P1 — queue rows struck MERGED with unmet acceptance, and one open row aimed at the graded db

- **Q6** (`docs/WORKTREE_QUEUE.md:63`) instructs an agent that normalisation is "absent from
  Cloud … nothing creates it today" — `TODOS.md:134-141` says it has been **live on `sonyliv`**
  since the tier-coherence rebuild (5 UDFs + 4 views, verified read-only, current pair
  1,774 → 2,196). An agent pulling Q6 attempts a redundant schema change **against the graded
  database**. This is the most operationally dangerous doc-drift item in the tree.
- **Q5** struck MERGED; its done-when requires "the filter-grain policy is decided and stated" —
  the policy is explicitly open (`WALKTHROUGH.md:206-207`, `doubts/06:12`).
- **Q15** struck MERGED with "`make ci` green, coverage 58.7–95.7%"; its done-when also required
  the **publisher state machine** covered — nothing in the merge touches
  `tools/publish.sh`/`sql/12_publish.sql`, and the 80% target is unmet at the 58.7% floor.
  Neither miss is noted at the strike-through.
- **Q17** closed on the link-rot half only; the "4 files violate the 7-line-summary rule" half was
  silently dropped.
- **Q1** (`docs/WORKTREE_QUEUE.md:53`) still present-tense alarms "observe reports a green gate as
  FAILED. Verified live" — fixed on dev (`e0dabc5`), fixtures assert the pass, TODOS agrees. The
  scariest open row in the queue is done and unmarked.

### 4.5 P1 — "no concurrency serves as no row" holds only at the grains ADR 0016 touched

The minute-grain views have no zero filter: `v_concurrency_minute` (`sql/20_views.sql:120-131`)
and `v_concurrency_minute_delta_total` (`sql/20_views.sql:136-144`) emit `concurrent = 0` rows
wherever a publisher retraction leaves net-zero change points, while a from-scratch rebuild emits
no row at all. The shipped DIMENSION-FLIP test *creates* this state (the vacated `IPHONE` cells
retain cancelled ± pairs), and the harness compares exactly the grains where it cannot show:
compare item 1 reads the delta *table* by signed sum (net zero ≡ absent — passes), items 3/4 read
only the *total*-grain minute view (the flip is invisible at total grain), and the per-dimension
minute views are not compared at all. Consequence: dashboards and any "minutes observed" count
differ between the incremental and rebuilt states at per-dimension minute grain; peaks and
averages are unaffected. The same filter asymmetry appears at window grain:
`v_cc_tumbling_hour` (`sql/85_windows.sql:437-447`) and `v_cc_window_range`'s hour CTE
(`sql/85_windows.sql:516`) read `cc_hour_agg FINAL` without the `peak != 0 OR integral != 0`
tombstone filter the hour/day views apply, so an ADR 0016 retraction tombstone serves as a zero
row there (and pads `hrs`). Latent until the publisher deploys; a rebuild's TRUNCATE clears it.

### 4.6 P1 — the hour-tier retraction guarantee silently depends on an engine the comments misname

`sql/50_hour_agg.sql:72-73` (and the ADR discussion around replay) calls `cc_minute_delta` "a
SummingMergeTree of sums with no dedup". The actual engine is **AggregatingMergeTree** with
`SimpleAggregateFunction(sum, …)` columns (`sql/10_intervals.sql:157-163`). The difference is
load-bearing for ADR 0016: SummingMergeTree **deletes rows whose summed columns are all zero at
merge time**, which would make "cancelled deltas keep the GROUP alive" (the mechanism that emits
the all-zero retraction tombstone for a fully-vacated hour) a race against background merges — a
stale nonzero hour row would then survive FINAL invisibly, and the commented-out hour reconcile
would never catch it. AggregatingMergeTree keeps the zero rows, so the shipped code is correct —
but only by the margin of a comment being wrong. Whoever "fixes" the engine to match the comment
converts a correctness guarantee into a merge-timing coin flip. The convergence tests cannot see
it: the FLIP/SHRINK phases run seconds after emit, before merges plausibly fire.

### 4.7 P1 — remaining evidence-integrity items

- **The migration branch has never executed.** `tools/build-model.sh:66-79`'s
  engine-detect → DROP path is exercised by no test (`publish-test.sh` creates fresh new-engine
  tables); its first real run is scheduled to be against `sonyliv`.
- **Stale numbers citing a regenerated evidence file:** `TODOS.md:24` and
  `docs/ARCHITECTURE.md:102,125` still say the 46-minute straggler corrected in "3.4 s"; the
  current `evidence/publish.txt` (regenerated by the ADR 0016 harness) records
  `total_ms = 5215` for that stage, and ADR 0013's phase table/"31,094 rows" no longer appear in
  the file both docs cite. ADR 0013 §"All from evidence/publish.txt" is now a false attribution
  (legitimate as dated history, wrong as a pointer).
- **`docs/EXPLAINER.md` is split-brain:** §C.1 correctly establishes 148,900 rows / **5.3×** as
  the honest delta-reduction number, while §D.1 (line 723) still presents the ~185,000,000-row
  Cartesian framing, and `.claude/skills/interval-math/SKILL.md:90` still teaches ~6,600× — the
  exact overstatement commit `ca9112b` was written to kill (the deck itself is clean; grep
  confirms). EXPLAINER also still says "dedup **proven inert**" unqualified (`:550,404`) against
  three sibling docs carrying the filter-grain retraction; still lists `/bench` and the deck as
  missing (`:700-701,894`) though both merged today; and still presents refreshable MVs as the
  continuous-publication answer (`:687-697`) where ADR 0013/0016 shipped a finalizer.
- **Scale claims:** the "gate passes on all 6,799 minutes at 100×" family
  (`EXPLAINER.md:871,898,992`; `checklist.md:156`) upgrades what `evidence/scale.txt:286` actually
  ran — the Level-1 delta-vs-interval self-consistency check — into "the gate" (Level-2 recomputes
  truth from `ev_raw`; it never ran at 100×). The thread-sweep pair "2.59 GiB / 50.5 s"
  (`EXPLAINER.md:874,974-976`) is in no committed evidence file (`scale.txt:301-305` says
  2 threads → 2.67 GiB / 55.1 s); direction holds, figures unauditable. The 100×-OOM caveat
  itself is consistently disclosed everywhere — confirmed not dropped.
- **Dossier 05 vs codex 002:** `doubts/05:47` measures 505 intervals / 493 sessions (matching
  001 §4.2) and never mentions 002 §7's conflicting 518 / 506 — the audit the repo itself declares
  supersedes 001 where they differ. Likely cause is 002's split-generation snapshot; nobody says
  so. Related: `WALKTHROUGH.md:231` and `WORKTREE_QUEUE.md:55` still quote 91 min / 302
  viewer-minutes where the dossier of record measured 92 / 305.
- **Negative gate tests are claims, not tests:** the "inject one bad delta row → exit 1" and "500
  fabricated viewers → FAILS" statements (`WALKTHROUGH.md:150`, `TODOS.md:11-13`) correspond to no
  committed evidence and no injection mode in `tools/reconcile.sh` — unreproducible as shipped.
- **Stale-in-the-safe-direction:** `docs/TESTS.md:84,110-113` and `WALKTHROUGH.md:161` still
  describe the truncation evidence as pre-ADR-0009/failing; the regenerated
  `evidence/truncation.txt` converges at 1,579 minutes / peak 2,917 (its own line 91). The
  permissive-pause arm "never re-measured" claim (`TODOS.md:78-83`, `WALKTHROUGH.md:236-240`) is
  also false — ADR 0012's consequences record the re-measure (peak 3,036 / 2,070.0 h).

### 4.8 P1 — test-suite residuals (focused pass; deep audit owned elsewhere)

The headline is positive — see §6.1. Residuals: the reconcile parser's pass/fail hinges on four
SUMMARY token names (`internal/pipelinehealth/reconcile.go:104-107`); a rename in
`sql/90_reconcile.sql:230-233` would keep the Go suite green on the stale fixtures while `observe`
false-alarms — cheap fix is a test that parses the committed `evidence/reconcile.txt` itself.
`internal/config/config_test.go:51-59,115-123` accept any non-nil error despite promising
named-variable errors. The driver-fake tests pin scan-destination shapes that only an integration
run validates against the real views. "~1,363 lines of new Go tests" counts 72 lines of
Makefile/docs; the Go-test figure is ≈1,302.

### 4.9 P2 — stale numbers, conventions, hygiene

- `sql/50_hour_agg.sql:373`: commented reconcile result says "Day peak for 2026-07-26 = 2887 at
  10:56, **matching the known global peak**" — the known peak is 2,917; the comment is a
  pre-ADR-0009 remnant inside a file merged today. `docs/OBSERVABILITY.md:129` similarly shows a
  "peak 2887" example gate line.
- Mentor-question count drift: `TODOS.md:173` "16" · `doubts/README.md:5` "17" ·
  `docs/MENTOR_QUESTIONS.md:3` "Seventeen" with 18 `Q` headers. `AGENTS.md` "doubts/02 worth
  9.7%" vs the rebased 9.6% (`EXPLAINER.md:279`).
- 28,073 vs 28,074 delta rows disagree *within* `EXPLAINER.md` (441 vs 459 vs 792) and within
  `WALKTHROUGH.md` (15/101 vs 154). `docs/CLICKSTACK.md:127` quotes the pre-0009 interval count.
  `doubts/04` headline pair 1,768 → 2,180 vs live 1,774 → 2,196 (context labeled, summary stale).
- `docs/VERIFIED.md`: the ADR 0016 entry ("2 → 1 across 4 physical rows", `-If` assignability,
  the `ARRAY JOIN`/`WHERE` probe) names no query text, evidence file, or commit — unlike its
  neighbors; the file header still says 26.7.1.1315 / 30-31 Jul while three sections are
  26.2.1.525 / 08-01, and it carries the 28,074 figure.
- "PHASE 8" projection pointers (`WALKTHROUGH.md:256`, ADR 0013:177, `V0_CHECKLIST.md:168`) now
  point at PHASE 10 in the regenerated `evidence/publish.txt` (the projection numbers themselves
  — 104,640 → 8,193 rows, +91% storage — all verify).
- Worksheets exist for five of nine merges; Q12/Q14/Q15/Q4·Q7 have none — the
  worksheet-per-session contract was skipped by four sessions. `4dabfa3`'s message says the
  doubts collision was "caught before either wrote"; `doubts/06` had merged one minute earlier.
- Demo: on sanity MISMATCH the runner warns and continues live (`demo/run.sh:103-105`); the `q()`
  write-blocklist is substring-based (fine as defense-in-depth). The beat-0 sanity check reads
  only `ev_raw` count + day-tier peak, so the codex-002 minute/hour split passes sanity and would
  put 2,887-generation minute curves on screen under a 2,917 talk track — `demo/SCRIPT.md:127`
  names the wrong-generation mode but its detector cannot see the split variant.
- `evidence/benchmark/`: the "dataset checksum" in `meta.env` is grepped out of
  `tools/fetch_data.sh` (bench.sh:110-111), i.e. provenance of what the CSV *should* be, not a
  hash of what `sonyliv` contained (row counts are the only linkage). `.claude/commands/bench.md`
  table spec drifted from the actual 8-column output.
- `docs/CLICKSTACK.md`'s new panel-reference blockquote pushed its Summary below `head -7` —
  the one outright new violation of the 7-line rule found among today's docs (all new ADRs,
  dossiers, and worksheets carry summary heads).

## 5. What the docs scoping pass actually closed

Q4+Q7's stated goal was "every headline claim has one scope and one current number." Verified
closed: the deck (no "185" or "6,600" survives — grep), `checkpoint/1.md` (frozen-record banner,
self-documented non-reproducing figures), the naive-peak 3,708-vs-3,743 confusion (explicitly
reconciled in `docs/CLICKSTACK_DASHBOARDS.md:86-100`), and the WALKTHROUGH summary's
incremental-vs-batch contradiction from 001 §7.3 (now correctly scoped — though its replacement
clause "no path for the hour/user tiers anywhere" became today's falsehood, §4.1.3). Verified
still open: everything in §4.7's EXPLAINER list. The pass moved the repo from "docs disagree with
evidence" toward "two docs and one skill disagree with the rest"; it did not finish.

## 6. Confirmations — checked and sound

### 6.1 The Go test merge (`f011818`, `2ea5dde`)

No stub-passers found on graded-path code. `testdata/reconcile_green.txt` matches the current
emitter exactly (7 columns with `ord`/`scope`; provenance diff against
`git show d6c85e2:evidence/reconcile.txt` differs only in the commit line — a genuine re-capture,
not a hand-written fixture). The old 5-column format is pinned as NOT-a-pass and a
future-added-column case is covered — the shipped bug class cannot recur silently in the tested
direction. `make ci` reproduced fully green with the pinned golangci-lint 2.12.2 and refuses
loudly (with instructions) on wrong-version and absent-binary branches (`Makefile:66-77`) — codex
001 §6.3's silent toolchain failure is closed in the refuse-loudly sense. Coverage moved exactly
as claimed and past 001's numbers: cmd 0→58.7%, chdb 0→93.1%, config 77.6→87.9%, otelemit
19.6→95.7%, pipelinehealth 54.5→90.8%. `go test -race` green; no test touches any database
(verified: network activity is loopback httptest plus one refused dial).

### 6.2 The demo harness (`4323b37`)

Read-only confirmed: every DB statement passes a write-refusing wrapper (`demo/run.sh:41-49`);
all 10 beat queries are SELECT/WITH; beat 4's reconcile is DB-side pure SELECT and the local
evidence-file write is restored via `git checkout --`. Fallbacks are real and were forced in
`evidence/demo/rehearsal.txt`. Every hardcoded spoken number matches its committed fallback file
and the 2,917 / 1,978.1 h / 33.6% headline (beat-by-beat verified). `demo/chaos.sh` writes only
the local docker container and is not invoked by `run.sh`.

### 6.3 The benchmark bundle (`eb3edfa`)

All eight codex 001 §4.10 demands are materially present (query text, params, answers, latency,
rows/bytes, query IDs with `log_comment` tags, commit `bfc5092`, dataset sha256 pins + row
counts). No benchmark query reads `ev_raw` — serving-layer only, with read_rows at serving scale.
Medians recomputed from `runs.tsv` for all 13 queries — all correct; answer-file sha256 verified
against the `hash` column; natural jitter in wall/elapsed with constant read_rows — no signs of
hand-editing. b01/b06 return peak 2,917 at 10:56 against `sonyliv` in its coherent post-rebuild
generation. `tools/bench.sh` contains no write statements. The "reconstruction, not the official
set" disclaimer is prominent in both the README and `bench.txt`.

### 6.4 Cross-checked headline web

The gate quartet (17,028 / 0 / 0 / peak 2,917) is identical in `evidence/reconcile.txt:8` and
every doc that quotes it. 1,978.1 h / 2,976.9 h / 33.6% match evidence everywhere quoted. User
peak 2,844 is proven by both routes in the regenerated `evidence/publish.txt`, read back through
HyperDX (`evidence/clickstack-dashboards.txt:112`), and now confirmed live in this review; 2,845
and 2,953 exist only as labeled historical readings. ADR 0016's measured table matches
`evidence/publish.txt` line-by-line. ClickStack counts (24 sources / 6 dashboards / 41 tiles)
match their evidence. The Q19 dossier renumbering is clean (`grep -rn Q19` → one queue row;
`doubts/` is exactly 01–06 + README with append-only numbering intact). The crash/concurrency
invariants (001 §4.3–4.5) were **not** dropped by queue churn — Q8–Q11 still carry them, and ADR
0016 restates them open. Dossier arithmetic is internally exact (505 = 347+165−7;
4,210 = 905,558−901,348; 06 matches 001 §4.7 to the digit) and every dossier decision table
covers all mentor-answer arms plus no-answer.

## 7. Commands and evidence used

```sh
git fetch origin && git merge origin/dev          # step zero — fast-forward to 4dabfa3
git log / git show <merge>^ -- <file>             # conflict archaeology on TODOS/WALKTHROUGH
TARGET=cloud tools/ch "SELECT … system.tables"    # live engines: cc_user_minute, mv_user_minute…
TARGET=cloud tools/ch "… max(concurrent) / max(peak) / max(concurrent_users)"   # 2917/2917/2844
TARGET=cloud tools/ch "SELECT * FROM v_cc_publish_lag"                          # epoch-zero, inert
TARGET=cloud tools/ch "SELECT max(build_version), uniqExact(build_version) …"   # one generation
go test -race -count=1 ./…  ·  go test -cover ./…  ·  make ci                   # green (pinned lint)
bash -n <every audited script>  ·  grep sweeps for write statements / evidence numbers
```

No write of any kind was issued against any database. `make model`, `tools/build-model.sh`,
`tools/publish.sh`, and the demo runner were **not executed**; their behavior is established by
static read plus the committed evidence of their prior runs.

## 8. Required closure

1. Patch the two `argMax` call sites in `tools/unseen-run.sh` (and `sql/90_reconcile.sql:216`)
   with the ADR 0014 tuple, and add a queue item + regression check — before the unseen day.
2. Add the graded-database guard to `build-model.sh` and `apply-sql.sh` (the `publish.sh` pattern
   exists); remove the hardcoded `sonyliv` fallbacks from the ClickStack scripts.
3. Fix the publisher-scope statements in `WALKTHROUGH.md` (:10, :66, :191),
   `docs/ARCHITECTURE.md` (:5-6, :70-74), `checklist.md`, `V0_CHECKLIST.md`; reconcile the queue's
   ADR ledger and the six stale "ADR 0016/0015/0018 pre-assigned" pointers, starting with
   `doubts/06`.
4. Either re-run the window and content reconciles on the current model and commit evidence, or
   strike both rows from WALKTHROUGH's "verified" table.
5. Correct the Q6 queue row before any agent pulls it.
6. Add the zero-row filter to the minute-grain and window views (or document the
   zero-vs-absent contract), and fix the SummingMergeTree comment in `sql/50_hour_agg.sql` before
   anyone aligns the engine to it.
7. Finish or re-disclaim EXPLAINER (§C.6/D.1/E.2/E.3) and fix `interval-math/SKILL.md:90`.
8. Exercise the `cc_user_minute` migration branch in scratch before its first run on `sonyliv`.

## 9. Final conclusion

What can be claimed now:

> The nine merges shipped working, evidence-backed machinery: a four-tier incremental publisher
> proven convergent in scratch including retraction shapes, a real parser fix with
> regression-pinned fixtures, a rehearsed read-only demo, and a complete benchmark bundle — and
> the graded database is verified live to be on one coherent model generation matching every
> headline number.

What cannot be claimed:

> That the repository's documentation agrees with its own code about the publisher's scope; that
> the submitted unseen-day peak minute is deterministic; that the graded database is protected
> from its own tooling; that "verified" means current evidence for the window and content tiers;
> or that "no concurrency serves as no row" holds at any grain ADR 0016 did not explicitly touch.
