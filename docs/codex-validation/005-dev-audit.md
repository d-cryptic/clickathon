# Codex Validation 005 — Whole-dev landing audit

> **Historical terminology notice:** this audit predates upstream `c1e1c69`; current evaluation uses
> required result classes and judge raw-event spot-checks, not a fixed private answer key.

> **Summary:** Reviewed `dev` at `c85dcd2` after merging it into `docs/dev-audit`; every ClickHouse Cloud operation in this audit was a `SELECT` against `sonyliv`.
> The live database is coherent now: 905,558 raw rows, 30,323 intervals, 28,073 delta rows, peak 2,917, and the 17,028-minute reconcile has zero mismatches.
> Two P0 paths remain: direct `apply-sql.sh` INSERT/CREATE files and `load.sh --replace` can still write the graded database without a graded-write acknowledgement; and the advertised one-command unseen run does not invoke the source-contract gate, so seconds-as-milliseconds can still produce a 1970 answer under a green reconcile.
> The headline measurements hold under independent read-only reconstruction: `TAIL_S` is 7.2x more elastic than `GAP_S`; 8,978 intervals take tail; the live edge has 65 wrong cells of 542,537, all final by age 240 s; and the spike evidence is exactly 2,917 + N.
> Q34's published live sizing is false: current serving has 82 user-greater-than-session cells, not 28, and 63 have users with zero sessions; the worst excess remains +1 and totals remain safe.
> Q35 is real: the spec interpreter over current Cloud rows gives peak 2,927 versus model-compatible 2,917, 80 changed minutes, max delta 16, and +18,127 seconds; the judge semantic choice is still unresolved.
> The synthetic golden cohorts and default reference interpreter are genuinely independent, but the organiser-file cohort is only a regression pin, the decline-alert classifier's claimed semantic anchors do not hold, and the business document contains stale and arithmetically false statements despite its correct CPM calculation.

## 1. Verdict

`dev` is serving one coherent model generation and most new measurements are reproducible. It is not
ready to be treated as fully reviewed, because two paths can still cause the two highest-consequence
failures in this project: corrupting the graded database and submitting a self-consistent but
nonsensical unseen-day answer.

Severity means:

- **P0** — can corrupt graded state or silently change the submitted headline under a green gate.
- **P1** — wrong filtered answer, load-bearing validation overclaim, or operational classifier that
  can take the wrong action.
- **P2** — stale or false documentation that does not itself move the served headline.

| Area | Verdict | Severity |
|---|---|---:|
| Current graded state and reconcile | **Sound now** | confirmation |
| Graded write guards | **Incomplete: INSERT/CREATE and loader paths remain** | **P0** |
| Unseen source-contract integration | **Gate exists, but is manual and absent from the one-command run** | **P0** |
| Decline classifier semantics | **Threshold rationale is numerically false; `end_coverage` is not a share** | **P1** |
| Q34 user <= session | **Real defect, incorrectly sized in queue/docs** | **P1** |
| Q35 point activity | **Real and independently reproduced; correct convention unresolved** | **P1** |
| Golden/reference independence | **Synthetic/spec paths sound; organiser PASS is regression only** | **P1 evidence** |
| Malformed-row load blast radius | **Real, loud, and leaves half-populated state** | **P1 ops** |
| Business arithmetic/docs | **CPM arithmetic sound; three stale/false claims** | **P2** |

## 2. Snapshot, scope, and safety

- Required merge: `git fetch origin && git merge origin/dev`, fast-forward `2b551b5..c85dcd2`.
- Required merge witnesses: `docs/BUSINESS_RULES.md` and `evidence/live/README.md` are present.
- Reviewed branch: `docs/dev-audit`; Superconductor target branch: `dev`.
- Live service: ClickHouse Cloud `26.2.1.525`, database `sonyliv`.
- Live operations: **SELECT only**. I did not run `make model`, `build-model.sh`, `publish.sh`, any
  loader, any DDL, any INSERT, or either graded override.
- Ownership: this report is the only repository file changed.

Method: for each claim, I first stated the condition that would make it defective, then checked that
condition using current source, a fresh read-only Cloud query, or both. Saved evidence was accepted
without a fresh run only where rerunning would write state or overwrite evidence; those cases are
called out explicitly.

## 3. P0 findings

### 3.1 P0 — the graded-write guard still permits answer-changing INSERT and CREATE paths

**What would have to be true.** The new non-overridable `GRADED_DB` fix would still be incomplete if a
normal repository tool could mutate `sonyliv` without either `REBUILD_GRADED=yes` or
`APPLY_GRADED_DESTRUCTIVE=yes`.

**It is true.** `tools/build-model.sh:84-93` correctly uses `readonly GRADED_DB=sonyliv`, closing the
caller-overridable-name hole. But `tools/apply-sql.sh:166-192` deliberately gates only destructive DDL.
It permits INSERT and `CREATE OR REPLACE` against `sonyliv` with no acknowledgement:

```text
sql/30_build_intervals.sql  guard=allowed  INSERT/CREATE lines=1
sql/20_views.sql            guard=allowed  INSERT/CREATE lines=6
sql/50_hour_agg.sql         guard=allowed  INSERT/CREATE lines=6
```

That was reproduced without executing SQL by running the exact guard predicates from
`tools/apply-sql.sh:181-182` over those files. `sql/30_build_intervals.sql:70-73` is an INSERT with a
new `build_version`; applying stale derivation SQL directly can make `session_intervals FINAL` choose
that generation while `cc_minute_delta` remains on the old one — the split-generation incident shape.
Replacing a serving view with stale SQL is answer-changing even though no table is dropped.

The loader remains a second path. `tools/load.sh:389-428` treats `--replace` as sufficient authority
to truncate any resolved database, and `tools/load.sh:436-440` then inserts both datasets. There is no
`sonyliv`/graded-name check anywhere in that script. The default non-empty refusal is valuable, but
`--replace` bypasses it by design and no graded-specific acknowledgement is required.

**Why I did not execute the reproduction.** Either exact command would write the graded database and
violate this audit's primary prohibition. The static path is complete: database resolution reaches
`sonyliv`, the guard evaluates false for the listed files, and the next operation is the shown write.

**Consequence.** The earlier `GRADED_DB` fix protects the rebuild wrapper but not the underlying
writer. A stale direct apply can again create a plausible split generation; a loader invocation can
truncate the raw source itself. This is a P0 until every project-managed graded write path requires a
non-overridable, explicit graded acknowledgement (or is read-only by policy).

### 3.2 P0 — the one-command unseen path omits the gate that catches timestamp units

**What would have to be true.** The seconds-versus-milliseconds incident remains actionable if the
command advertised as the complete unseen run can reach the answer and reconcile without invoking
the source-contract check.

**It is true.** `tools/load.sh:205-208` divides both timestamp columns by 1,000 unconditionally.
`queries/validate_source_contract.sql:84-87` now correctly marks years outside 2020..2035 as FAIL,
and `docs/RUNBOOK_UNSEEN.md:48-77` tells the operator to run that gate in a throwaway database.
However:

- `tools/unseen-run.sh:3-16` calls itself the entire pipeline;
- its executable phases at `tools/unseen-run.sh:249-412` never invoke
  `tools/validate-source-contract.sh`;
- `docs/RUNBOOK_UNSEEN.md:83-90` calls the unseen-run invocation "the whole thing";
- the runtime model and reconcile still read `ev_raw` directly
  (`sql/30_build_intervals.sql:135`; `sql/90_reconcile.sql:59,92,172`);
- `v_ev_model_input` is explicitly not wired (`docs/PREPROCESSING.md:74-85`), and the unseen runner
  does not apply `sql/15_normalise.sql` at all.

Fresh read-only arithmetic against Cloud reproduced the unit relocation:

```text
input seconds     1785063241
loader expression toDateTime64(value / 1000, 3)
loaded value      1970-01-21 15:51:03.241
source gate       FAIL (year outside 2020..2035)
```

The committed end-to-end hostile rehearsal is stronger: `docs/CRUEL_DATA.md:89-97` records one such
session becoming the submitted `peak 1 @ 1970-01-21`, while the reconcile compared 30,315,496 minutes
with zero mismatches. The gate is green because both model and truth read the same poisoned `ev_raw`.

**Consequence.** The defense exists, and the current delivered file passes it; it is procedural rather
than enforced. Skipping one preliminary runbook section produces a green, wrong submission through
the command labelled complete. Integrate the FAIL probes into the one-command preflight or stop calling
that command the whole path.

## 4. P1 findings

### 4.1 P1 — the decline alert's semantic anchor is inverted, and its coverage ratio is not a share

**What would have to be true.** The classifier is not semantically anchored if normal viewer behavior
can satisfy the OUTAGE threshold, or if `end_coverage = 1` does not actually mean every departure is
explained.

**Both are true.** `docs/DECLINE_ALERTING.md:90-94` cites ADR 0007's paused rate of 0.756
heartbeats/session/minute, then claims that `hb_per_session < 1.0` is quieter than a fully paused fleet.
Numerically, 0.756 is already below 1.0, so under the document's claimed comparability the fully-paused
reference lies inside the heartbeat half of OUTAGE, not above it.

The quantities are not actually comparable either: ADR 0007 measures heartbeats per paused
exposure-minute, while the alert divides raw heartbeats in a wall-clock minute by served any-overlap
**active** concurrency, which excludes paused sessions. Thus the claimed anchor fails whichever way it
is read: the stated inequality is backwards, and the implemented denominator is from another
population.

Fresh read-only execution of the current classifier returned:

```text
class    minutes  hb/session range  end_coverage range
ENDING       17   3.248..6.095      0.917..1.703
OUTAGE       11   0.000..0.071      0.000..0.035
```

`end_coverage` reaching 1.703 disproves its documented interpretation as a share for which 1.0 means
all departures are accounted for (`docs/DECLINE_ALERTING.md:87-89`). The numerator counts raw
`VideoSessionEnd` rows (`tools/clickstack-alerts.sh:156-170`), while the denominator is modeled net
concurrency loss plus starts. End events may repeat (14 sessions do so in the current source-contract
report), and their event minute does not align with the model's tail-adjusted departure minute.

**Consequence.** The detector's 28 firing minutes are reproducible, but the cause labels are not
anchored as claimed. The only observed OUTAGE is file truncation, and disengagement is explicitly
unobserved (`docs/DECLINE_ALERTING.md:137-155`). A normal-behavior false positive was not demonstrated;
the P1 is that a page-producing classifier is shipped with an invalid threshold argument and no real
playback-outage positive example.

### 4.2 P1 — Q34 has 82 violating cells, not 28, including 63 zero-session cells

**What would have to be true.** The queue's sizing is false if it compared a stale generation, a
different grain, or a sparse curve without carrying values across unchanged minutes.

**It is false on the coherent current generation.** `docs/WORKTREE_QUEUE.md:146-160` claims 28 cells,
worst +1, and zero cases with sessions=0. I aggregated `cc_minute_delta` to the user tier's
`(platform,country,content_id)` grain, reconstructed the running count per hour, carried each change
point to the next one, and left-joined the dense result to `v_user_concurrency_minute`.

Fresh Cloud result:

```text
violations          82
max_excess           1
sessions=0/users>0  63
distinct minutes    52
distinct grains     14
range                2026-07-25 20:23 .. 2026-07-26 11:24
```

This matches `evidence/property/README.md:106-130`, not the queue. The cause is also confirmed:
`sql/40_deltas.sql:71-74` keeps the first interval's dimensions when minute-touching session
intervals merge, while `sql/45_user_concurrency.sql:87-155` expands and attributes each interval.
The tiers are individually faithful to different conventions and jointly violate users <= sessions.

**Consequence.** The total peaks remain safe (users 2,844, sessions 2,917), and the worst error is one,
but 63 filtered dashboard cells present a user with no session. Exact private queries at that grain
can find it. The Q34/ORCHESTRATION claims of 28 and zero orphans must not be quoted.

### 4.3 P1 — Q35's point-activity delta is real; the gate cannot settle the convention

**What would have to be true.** The claimed +10 peak is real if a spec implementation independent of
SQL produces it from current Cloud rows and model-compatible mode still reproduces the shipped model.

**It does.** I streamed only `(session_id, event_type, event, timestamp_ms)` from current `sonyliv`
into `tools/reference_interpreter.py`, using constant dummy dimensions because this check is total
concurrency. Results:

```text
rows                 905,558
compat intervals      30,323
compat watch seconds 7,121,135
compat peak             2,917
spec intervals        29,146  (the spec merges contiguous seconds differently)
spec watch seconds   7,139,262
spec peak               2,927
changed minutes            80
max minute delta            16
```

The +18,127 seconds is 5.04 hours. A separate read-only run-split query found exactly 182 zero-span
runs across 175 sessions. `sql/30_build_intervals.sql:298-302` drops zero-length segments before tail,
and `sql/90_reconcile.sql:113-149` carries the same convention, so a green reconcile cannot decide it.

**Consequence.** The measurement is sound. Whether point activity should earn a cadence is a ground-
truth convention, not something another self-consistency gate can prove. Until decided, 2,917 is the
shipped answer and 2,927 is a measured alternative, not an automatic fix.

### 4.4 P1 evidence — the organiser golden is a regression test, not an independent oracle

**What would have to be true.** A circularity exists if the supposed external expectation is the old
pipeline answer or knowingly ports the implementation under test.

**For the organiser cohort, both are true.** `tools/golden-gen.sh:406-412` hard-codes the last green
reconcile as `PIN`. It then calls `derive_intervals(..., model_compat=True)` at
`tools/golden-gen.sh:429-456`. The compat function explicitly describes itself as the shipped segment
fold and a "knowing port" (`tools/reference_interpreter.py:161-185`). Agreement among that port, a pin
created by an older SQL run, and current SQL is a valuable regression check; it cannot establish that
the shared semantics match judge spot-check expectations.

The documentation partially admits this in the results table (`docs/GOLDEN.md:25,41`) but overclaims
independence in its title, summary, and rationale (`docs/GOLDEN.md:1-16,54-57`).

**The rest of the suite is not circular.** I checked the synthetic expected-value builders: their
curves are constructed arithmetically outside SQL. `GAP_S` and `TAIL_S` are hard-coded in the harness
and asserted against SQL (`tools/golden-gen.sh:112-129`), so a drift fails instead of silently changing
the expectation. The lone-event cohort deliberately disagrees with SQL. Default spec mode in the
reference interpreter uses a set-of-seconds implementation (`tools/reference_interpreter.py:136-158`)
and found Q35; the property suite also found Q34. Those are observable demonstrations of independence.

**Consequence.** Keep the organiser cohort, but use its PASS only for "the headline did not move".
Treat the synthetic golden cohorts and default spec-mode properties as the external correctness
evidence. The current blanket "every expectation is outside the pipeline" wording manufactures more
confidence than the organiser test can provide.

### 4.5 P1 ops — one malformed timestamp still loses the raw batch after content commits

**What would have to be true.** The blast radius remains if the current loader inserts content first,
performs one typed raw INSERT, and has no tolerant landing layer before that parse.

**It remains true.** `tools/load.sh:436-440` inserts `content_dim` first and then sends all of `ev_raw`
through typed `input()`. `docs/PREPROCESSING.md:26-33,74-85` explicitly says a type mismatch rejects the
whole batch and that quarantine only receives already-typed rows.

The current committed reproduction is `docs/codex-validation/004-triage.md:70-107`: one value at data
row 499,999 changed to `NOT_A_TIMESTAMP` caused exit 27, `ev_raw=0` of 905,558, and
`content_dim=33,464`. A plain retry was then refused because one table was non-empty. Current source
still has the exact insert order and typed path used by that reproduction.

**Why I did not rerun it.** A fresh full reproduction would intentionally write and leave a scratch
database half populated, while the current source and saved exact stderr already close the factual
question. No Cloud write was permissible, and a tiny SELECT-only parse failure would not test the
atomicity or surviving content insert that make this finding material.

**Consequence.** This failure is loud, which is good, but recovery requires the destructive
`--replace` path. The source-contract and quarantine features cannot protect rows that fail before
`ev_raw`. The unseen-day priority remains tolerant typed conversion or a clearly rehearsed recovery
procedure.

## 5. P2 documentation and business findings

### 5.1 P2 — business arithmetic is correct, but the document did not absorb adjacent merges

The CPM illustration at `docs/BUSINESS_RULES.md:64-81` is correct:

```text
791 / 3,708 = 21.33% not watching
213 * 8 = 1,704 phantom impressions per 1,000 reported viewer-hours
1,704 / 1,000 * INR 200 = INR 340.8 (about INR 341)
at 1,000,000 reported: INR 340,800 = INR 3.408 lakh/hour
```

The assumptions are explicitly labelled illustrative and not SonyLIV figures, so their lack of an
external citation does not invalidate the arithmetic.

Three statements are stale or false:

1. `docs/BUSINESS_RULES.md:36` says all 10,758 runs whose final second has `VideoSessionEnd` collect
   tail. Fresh live reconstruction gives 10,758 such runs, but only **7,454** pay tail; **3,304** do
   not. Only 8,978 runs of any ending class pay tail in total.
2. `evidence/business/README.md:3-8` still gives the discarded waterfall (+246.2 h tail and 382.8 h
   pause), while its corrected body at lines 88-102 gives +149.6 h tail and -286.2 h pause.
3. `docs/BUSINESS_RULES.md:123-128` says decline alerting is unbuilt and uses same-time-yesterday.
   The merged implementation rejects same-time-yesterday and ships a lagged trailing median
   (`docs/DECLINE_ALERTING.md:46-81`).

These do not move current serving, but this is exactly the cross-merge staleness the repository's
"change that outdates a doc updates it in the same commit" rule is intended to prevent.

## 6. Independent confirmations of load-bearing claims

### 6.1 Current Cloud state and reconcile — confirmed sound

Fresh reads returned:

```text
ev_raw              905,558
session_intervals    30,323
cc_minute_delta      28,073
reconcile minutes    17,028
mismatched                0
max absolute diff         0
peak                  2,917
```

I first scanned `sql/90_reconcile.sql` for write tokens, then executed it directly as a SELECT. The
source-contract gate also ran read-only: zero FAIL probes, with the expected three WARN classes
(`ingested_at`, 14 multiple-end sessions, 4,209 duplicate rows).

### 6.2 `TAIL_S` versus `GAP_S` — confirmed sound

I removed only the INSERT envelope from current `sql/30_build_intervals.sql` and ran its body as a
read-only SELECT over Cloud. Relevant sweep points:

| GAP_S | TAIL_S | intervals | peak |
|---:|---:|---:|---:|
| 120 | 60 | 30,467 | 2,919 |
| 135 | 60 | 30,391 | 2,918 |
| 150 | 60 | 30,323 | 2,917 |
| 165 | 60 | 30,265 | 2,914 |
| 180 | 60 | 30,214 | 2,909 |
| 150 | 0 | 30,323 | 2,758 |
| 150 | 40 | 30,323 | 2,872 |
| 150 | 80 | 30,323 | 2,968 |
| 150 | 120 | 30,323 | 3,047 |

Thus GAP 120->180 spans 10 viewers (0.34%). Central slopes are -0.133 viewers/gap-second and
+2.400 viewers/tail-second; normalized elasticities are 0.0069 and 0.0494, a 7.2x ratio. Tail
0->120 adds 1,077,360 watch seconds; dividing by 120 gives exactly **8,978** tail-paying intervals,
29.6% of 30,323. The endpoint peak slope is 289/120 = 2.408 viewers/tail-second, supporting the
reported 2.41 straight-ramp fit.

### 6.3 Live edge — confirmed sound independently and read-only

I reran all 32 as-of cuts directly against Cloud with the current derivation body plus only the prefix
predicate, then diffed their dense minute curves against current final intervals. No scratch table was
created. The independent aggregate exactly matches `evidence/live/20-analyse.txt`:

```text
cuts                         32
cells                   542,537
wrong                        65
under / over               61 / 4
newest mean relative error -14.82%
wrong at ages 0/60/120/180 31 / 27 / 6 / 1
wrong at age >= 240 s        0
worst under / over        -446 / +2
```

At the peak cut, 10:56 is 2,471 versus final 2,917 (-446); by the 11:00 cut it is exact. The claim is
load-bearing and sound. One stale sentence remains in `evidence/live/README.md:73-81`: it says the
graded database currently fails reconcile, which is no longer true after the rebuild.

### 6.4 Spike `2,917 + N` — sound from construction and saved gates

I did not rerun the 17.3-million-event 100k local generator because it writes scratch databases and
overwrites owned evidence. I instead inspected the generator and both saved gate outputs.

`tools/spike-test.sh:57-63` places every synthetic session's arrival before the baseline peak and its
departure after it; its generated heartbeats keep every session active across 10:56. Distinct session
ids make the exact addition structural. The committed incremental and batch gates independently show:

```text
N=1,000      peak 3,917    both gates PASS
N=10,000     peak 12,917   both gates PASS
N=100,000    peak 102,917  both gates PASS
```

Locations: `evidence/spike/spike.txt:120-163,261-303,388-430`. This confirms the claim to the extent a
deterministic synthetic load test can; it is not evidence about an unknown real spike's event quality.

### 6.5 The two unseen risks — both confirmed real, with different failure modes

- **Unparseable timestamp:** hard fail, exit 27, all 905,558 raw rows rejected, content survives.
  Loud but operationally hazardous; source contract cannot see a row that never typed (§4.5).
- **Seconds interpreted as milliseconds:** loads successfully into 1970 and reconcile stays green.
  The new source-contract probe detects it, but only if the separate manual step is run (§3.2).

The first is a load-atomicity problem; the second is a semantic-sanity problem. They should not be
collapsed into one generic "bad timestamp" issue because their defenses are different.

## 7. Claim ledger

| Claim from the audit brief | Result | How checked |
|---|---|---|
| `TAIL_S` 7.2x more elastic than `GAP_S` | **confirmed** | fresh read-only current-SQL sweep and elasticity calculation |
| 8,978 / 30,323 intervals take tail | **confirmed** | tail watch-second derivative and full derivation |
| Live edge: 65 / 542,537 wrong; 61 under; none age >=240 | **confirmed** | independent 32-cut read-only Cloud reconstruction |
| Spike peak = 2,917 + N at 1k/10k/100k | **confirmed** | generator construction plus incremental and batch saved gates |
| Q34: 28 cells, max +1, no zero-session cells | **false except max +1** | fresh dense served-grain reconstruction: 82 / +1 / 63 |
| Q35: 182 runs; peak 2,917 -> 2,927 | **confirmed measurement** | live rows through spec and compat interpreter; convention unresolved |
| One malformed timestamp loses full raw file and leaves content | **confirmed from current path + exact saved reproduction** | no fresh stateful rerun |
| Seconds/milliseconds moves answer to 1970 under green gate | **confirmed** | fresh conversion query + end-to-end hostile evidence + gate lineage |
| Golden/reference expectations are outside pipeline | **true for synthetic/spec; false for organiser regression** | source lineage and deliberate divergent cases |
| Business ad/CPM arithmetic | **confirmed** | direct arithmetic |
| Alert thresholds are semantically anchored, not fitted | **not established; heartbeat rationale is false** | arithmetic, denominator lineage, fresh classifier output |

## 8. What I could not verify

1. **Private-ground-truth semantics.** No internal test can decide whether a lone point earns a tail,
   whether explicit end should suppress tail, or which minute-boundary reading the grader uses.
2. **A real playback outage or disengagement episode.** The file contains a truncation cliff, no
   unclosed sessions, and no observed disengagement class. The alert's cause labels therefore lack
   representative positive examples.
3. **Hosted HyperDX remote state.** I audited the SQL and saved validation, not whether all three
   remote alerts are currently provisioned and enabled. Checking or changing control-plane state was
   unnecessary for the semantic findings.
4. **Fresh stateful reruns of load, spike, golden, or publisher harnesses.** They write scratch state
   and/or overwrite evidence outside this review's ownership. Where used, I named the saved evidence
   and independently inspected the implementation; all headline Cloud checks were freshly rerun as
   SELECTs.
5. **The unseen day itself.** The defenses can be inspected and rehearsed; its schema, timestamp units,
   vocabulary, cadence, and ground-truth conventions do not yet exist to inspect.

## 9. Priority order

1. Close every graded-write path, including direct INSERT/CREATE applies and loader replace/append.
2. Put source-contract FAIL checks inside the one-command unseen preflight before deriving an answer.
3. Correct or withdraw the decline classifier's semantic claims before enabling a real paging target.
4. Resolve the Q34 attribution convention and the Q35 point-activity convention as model+gate changes.
5. Relabel the organiser golden as regression-only and update the stale business/queue/live docs.

The current 2,917 answer is internally coherent and freshly gate-green. The review blocker is not the
present snapshot; it is that the repo can still destroy that snapshot or produce a green nonsensical
replacement through documented tooling.

## 10. Repository validation

`devbox run -- make ci` passed after the report was written: `go mod tidy`, `go vet ./...`,
`golangci-lint run ./...` (0 issues), all race-enabled Go tests, and the CLI build. A first bare
`make ci` correctly refused the globally installed golangci-lint v1.64.8 because the repository pins
v2.12.2; rerunning through the documented Devbox environment supplied the pinned toolchain.
