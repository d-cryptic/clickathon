# Codex Validation 007 — `main` submission audit after the 234-commit merge

> **Superseded by Codex Validation 009:** this audit predates the official unseen data and final
> submission rules. Its repository-visibility and Team-Captain findings are historical, not current
> requirements.
>
> **Summary:** Audited `main`/`dev` at `c642066` on 2026-08-02, read-only against the graded `sonyliv` database and with an isolated local negative test for the gate.
> All five submitted answers independently reproduce from `ev_raw`: peak 2,917 @ 10:56, 1,978.1 h, 33.6% excluded, user peak 2,844, and session-independent peak 2,894.
> The 17,028-minute gate is live-green and non-vacuous: one fabricated local scratch delta produced `mismatched=1`, `max_abs_diff=1`, and `MISMATCH`.
> Two judge-facing claims do not survive audit: Q34/Q35 are absent from both entry documents, and the claimed content-view reconcile is not contained in its cited evidence; rolling/tumbling correctness still has no current oracle at all.
> Q37 is supported by committed hostile-file runs and current source lineage, but a fresh end-to-end run was prohibited because `unseen-run.sh` is Cloud-write-only; Q38's 90/93/120 s totals count the source-contract gate twice and are not the one-command timings.

## 1. Verdict

The submitted headline snapshot is coherent and reproducible. The serving tables currently agree with
an independent Python implementation over raw events, and the reconciliation gate both passes the
full data and fails a deliberately corrupted scratch serving layer.

I would still **not submit the repository in its current judge-facing form**. The main technical
reason is not the 2,917 snapshot; it is the claim ledger:

1. Q35 changes a submitted answer (2,917 to 2,927 and +5.0 h) but is absent from both `README.md` and
   `SUBMISSION.md`.
2. Q34 violates `users <= sessions` in 82 filtered cells but is absent from both entry documents.
3. `SUBMISSION.md` labels an old global gate transcript as a content-view reconcile that it is not,
   while `WALKTHROUGH.md` correctly says that no such current evidence exists.
4. Rolling/tumbling correctness is still only a stale remembered result: no current test, evidence
   artifact, or queue owner exists.

There are also two independently disqualifying administrative blockers. `gh repo view` returned
`visibility: PRIVATE` for `d-cryptic/clickathon` on 2026-08-02, and the Team Captain field remains
blank at `SUBMISSION.md:30`.

Severity used below:

- **P0** — cannot submit or can produce/certify a wrong submitted answer.
- **P1** — must be corrected or explicitly disclosed before submission.
- **P2** — material evidence/documentation debt that does not move the five headline values.
- **CONFIRMED** — load-bearing claim independently held.

## 2. Scope, safety, and method

### Repository state

- Managed worktree branch: `docs/main-submission-audit`; target branch: `main`.
- `HEAD`, `origin/main`, and `origin/dev`: `c642066`; both comparisons were 0 commits apart.
- The worktree was clean before this report.
- Merge `f2d8abb` explicitly says that 234 commits landed via the operator fallback and that none
  passed the six-check promotion gate as a complete increment.

### Cloud safety

No Cloud write was issued. In particular, this audit did not run `make model`, `build-model.sh`,
`publish.sh`, `unseen-run.sh`, `cruel-gen.sh run`, or any Cloud `INSERT`, `CREATE`, `DROP`, `ALTER`,
`TRUNCATE`, or `OPTIMIZE`. No graded-write acknowledgement variable was set.

Per the vendored official ClickHouse rules `agent-discovery-schema` and `agent-query-safety`, I first
read `system.tables`, `system.columns`, the sort/primary/partition keys, skipping indexes, samples,
and an `EXPLAIN indexes=1`. Every agent-generated Cloud query had explicit execution, read, byte, and
result limits. The one full raw stream was bounded to the observed 2026-07-14 through 2026-07-26
range and to 1,000,000 returned rows.

The gate's negative test was local-only. It created exactly
`codex_gate_neg_dcee_20260802.{ev_raw,cc_minute_delta}`, proved a clean baseline, inserted one
fabricated `+1`, observed the failure, enumerated the two expected tables, and removed the scratch
database. The graded database was not involved.

## 3. Submitted answers — independently confirmed

### Finding A — all five submitted values reproduce from raw events

**Severity: CONFIRMED.**

**Locations.** `SUBMISSION.md:42-66`; `README.md:13-26,66-67`.

**Reproduction.** I streamed only the required raw columns from `ev_raw` into
`tools/reference_interpreter.py` and ran both modes:

- `model_compat=True`, the shipped convention, without reading `session_intervals`,
  `cc_minute_delta`, `cc_hour_agg`, or either serving view;
- spec mode, which retains point activity and therefore independently sizes Q35.

The wrapper computed session-minute sets, user-minute sets, watch seconds, and naive session spans
directly from raw event objects. A separate raw-only ClickHouse query computed the session-independent
curve as `uniqExact(video_session_id)` by event minute for `VideoHeartbeat`/`VideoPlay`.

| Quantity | Raw independent result | Submitted |
|---|---:|---:|
| rows / sessions consumed | 905,558 / 10,866 | 905,558 / 10,866 |
| compatible intervals | 30,323 | 30,323 |
| session peak | **2,917 @ 2026-07-26 10:56 UTC** | 2,917 @ 10:56 |
| counted watch time | 7,121,135 s = **1,978.093056 h** | 1,978.1 h |
| naive session-span time | 10,716,726 s = **2,976.868333 h** | 2,976.9 h |
| excluded share | **33.551208%** | 33.6% |
| user peak | **2,844 @ 10:56 UTC** | 2,844 |
| session-independent peak | **2,894 @ 10:56 UTC** | 2,894 |

A final read of the serving layer returned exactly the same values: session peak 2,917 at 10:56,
user peak 2,844, stateless peak 2,894, and 7,121,135 watch seconds.

**Limit of this confirmation.** The reference implementation is independent code, not an independent
definition. It deliberately shares the repository's `GAP_S=150`, `TAIL_S=60`, pause rule, whole-second
truncation, and inclusive any-overlap minute membership. It confirms implementation fidelity under
the shipped contract; it cannot decide the open semantic forks.

### Finding B — Q35 remains a real alternative answer

**Severity: P1 disclosure defect; model choice unresolved.**

**Locations.** `tools/reference_interpreter.py:1-65,136-185`; `docs/WORKTREE_QUEUE.md:172-188`;
`docs/BUSINESS_RULES.md:49,118`; absent from `README.md` and `SUBMISSION.md`.

**Reproduction.** The same raw stream in spec mode returned:

```text
spec intervals          29,146
spec watch seconds   7,139,262 = 1,983.128333 h
spec peak                2,927 @ 10:56
spec user peak           2,853 @ 10:56
changed minutes             80
max positive delta          16
```

That is +18,127 seconds (+5.04 h), +10 session concurrency, and +9 user concurrency. The open choice
is defensible either way, but the current answer is "point activity counts for zero" by an incidental
zero-length filter. `SUBMISSION.md:191` says known limitations are not hidden; omitting the one known
fork that changes both submitted peak and hours contradicts that promise.

### Finding C — Q34 is current, raw-reproducible, and absent from the entry documents

**Severity: P1 for filtered correctness/disclosure; headline totals unaffected.**

**Locations.** `docs/WORKTREE_QUEUE.md:146-170`; `evidence/property/README.md:106-134`; absent from
`README.md` and `SUBMISSION.md`.

**Reproduction.** With real dimensions in the same raw Python derivation, I applied the delta tier's
first-interval dimension convention and the user tier's per-interval convention at
`(minute, platform, country, content_id)` grain:

```text
violations       82
max excess       1
users>0/session=0 cells 63
distinct minutes 52
distinct grains  14
```

This exactly reproduces the corrected Q34 sizing. The total peaks remain 2,844 users and 2,917
sessions, but a judge filtering one of those cells can observe one user with no session.

## 4. Reconciliation gate — confirmed non-vacuous

### Finding D — the full gate is green on current Cloud state

**Severity: CONFIRMED.**

**Locations.** `sql/90_reconcile.sql`; `SUBMISSION.md:47-53`; `WALKTHROUGH.md:148-150`.

**Reproduction.** I executed `sql/90_reconcile.sql` verbatim as a read-only Cloud query after scanning
it for write operations. The result was:

```text
minutes_compared=17028
mismatched=0
max_abs_diff=0
peak=2917
PASS
```

The live source-contract gate also reported 0 FAIL probes and the expected three WARN classes:
one extra `ingested_at` column, 14 sessions with multiple end events, and 4,209 duplicate rows.

### Finding E — one fabricated delta makes the gate fail

**Severity: CONFIRMED.**

**Locations.** `SUBMISSION.md:51-53`; `WALKTHROUGH.md:149`.

**Reproduction.** In a local scratch database, one synthetic session and the correct `+1/-1` delta
pair first returned `minutes_compared=1, mismatched=0, PASS`. Inserting one additional `+1` at the
checked minute returned:

```text
minutes_compared=1
mismatched=1
max_abs_diff=1
truth=1 served=2 diff=1
MISMATCH
```

The SQL gate therefore can fail. I did not run `tools/reconcile.sh` itself because that command writes
`evidence/reconcile.txt`, outside this audit's single-file ownership; its exit decision is a direct
grep for the `MISMATCH` token observed above plus a nonzero `minutes_compared` check.

## 5. Unseen-day path

### Finding F — a fresh hostile end-to-end run was prohibited, not silently skipped

**Severity: verification boundary, not a pipeline verdict.**

**Locations.** `tools/unseen-run.sh:57,74-92,182-213,360,475,494`; brief prohibition.

**Why not reproduced live.** `tools/unseen-run.sh` is Cloud-only: it connects over the configured
Cloud host/native TLS, drops and creates the unseen database, loads rows with `TARGET=cloud`, and
truncates derived tables. `tools/cruel-gen.sh run` delegates to that path and also creates/drops Cloud
scratch databases. The audit brief forbids *all* `TARGET=cloud` writes, not only writes to `sonyliv`.
There is no supported local mode. Running either command would have violated the explicit safety
boundary, so I used source inspection, current lineage, local syntax checks, and committed transcripts.

### Finding G — Q37's runner fix is supported, with one evidence caveat

**Severity: qualified CONFIRMED / P2 evidence freshness.**

**Locations.** `tools/unseen-run.sh:222-319,418-471`; `tools/contract-runner-agreement.sh`;
`evidence/q37/README.md`; `evidence/q37/agreement.txt`.

Current source uses Python's RFC-4180 CSV reader to count records, allows new columns for the loader's
`extra` map, and invokes the source-contract gate after load and before interval derivation. `bash -n`
passed for the runner, loader, contract gate, agreement harness, and cruel generator.

Committed evidence at `4eb4746` shows:

```text
cruel-newline-raw.csv  gate ACCEPT  runner ACCEPT
cruel-newcol-raw.csv   gate ACCEPT  runner ACCEPT
ctl-misscol.csv        gate REFUSE  runner REFUSE-FILE
ctl-dupecol.csv        gate REFUSE  runner REFUSE-FILE
VERDICT: PASS
```

The model/load hashes printed by the accepted hostile runs match current main, and
`tools/unseen-run.sh`/`tools/load.sh` have not changed since that agreement evidence. However,
`tools/contract-runner-agreement.sh` itself gained 39 lines after the evidence to fix its refusal
classification and `set -e` behavior. The current harness has therefore not produced its own fresh
committed PASS. The valid-file acceptance result remains supported; the current four-fixture harness
result is not freshly evidenced.

### Finding H — `cruel-gen.sh` still describes fixed behavior as broken

**Severity: P1 unseen-day operator risk.**

**Locations.** `tools/cruel-gen.sh:157-170,875-960`; `evidence/q37/README.md:243-260`.

The hostile generator was not updated with Q37/ADR 0030:

- the newline manifest still says the runner should die on `wc -l`, although that was fixed;
- the new-column branch prints that successful acceptance means the header guard regressed, although
  successful acceptance is now the intended behavior;
- the bad-type manifest expects the typed insert to fail, although the all-String landing path now
  quarantines per row.

Thus `tools/cruel-gen.sh run <knob>` is not a reliable verdict surface even where the underlying
runner is correct. This is exactly the tool the audit brief asks an operator to reach for under time
pressure, so stale expected outcomes are more than cosmetic.

### Finding I — Q38's totals are real only for a two-contract path

**Severity: P2 claim precision.**

**Locations.** `SUBMISSION.md:143-167`; `docs/RUNBOOK_UNSEEN.md:105-126`;
`evidence/unseen/timings-2026-08-02.txt:18-45`.

The arithmetic in the timing evidence is correct:

| events | separate preflight | one-command runner | published total |
|---:|---:|---:|---:|
| 6.9k | 24 s | 66 s | 90 s |
| 30k | 26 s | 67 s | 93 s |
| 850k | 38 s | 82 s | 120 s |

But the evidence explicitly says the 66/67/82-second runner **already includes phase 2b**, another
source-contract execution. Therefore:

- 66/67/82 s are the current one-command end-to-end timings;
- 90/93/120 s are the runbook's redundant preflight-plus-runner timings, with the contract checked
  twice in two scratch databases;
- `SUBMISSION.md:150-152` presents the rows as one contract gate plus a "build" and does not say the
  build contains the second contract run;
- `SUBMISSION.md:164-167` links the older pre-ADR-0009 rehearsal, not the timing file that actually
  supports 90/93/120.

This is conservative rather than dangerous under-budgeting, but it is not a clean phase breakdown.

## 6. Judge-facing claims and disclosures

### Finding J — Q34/Q35 and the largest semantic fork are inconsistently disclosed

**Severity: P1.**

**Locations.** `README.md:102-113`; `SUBMISSION.md:189-230`; `docs/WORKTREE_QUEUE.md:139-188`.

- Q34 and Q35 appear in neither judge entry document.
- `README.md:107` calls the 9.7% resume fork the "largest measured fork". `SUBMISSION.md:216-230`
  correctly says minute membership is larger: 2,917 to 2,507, -410 viewers, -14.1%.
- The minute-membership fork is well disclosed in `SUBMISSION.md`; it is not well disclosed in the
  README section explicitly titled "What we know is still wrong".
- `README.md` says six evidence-backed questions; `SUBMISSION.md` says "five more" after doubt 02;
  the tree currently carries 12 numbered dossiers (`doubts/01` through `doubts/12`).

The merge commit knew all three facts (Q34, Q35, and the then-eleven dossiers), but commit messages are
not a judge-facing limitation ledger.

### Finding K — the content-view evidence citation does not prove its label

**Severity: P1 evidence overclaim.**

**Locations.** `SUBMISSION.md:55-62`; `evidence/reconcile-content-views.txt:1-53`;
`WALKTHROUGH.md:158`.

`SUBMISSION.md` labels `evidence/reconcile-content-views.txt` as "content tier, 0 mismatches". The
file contains:

- a **global** raw-vs-delta gate at the old 2,887 generation;
- a database-qualification check for the dictionary;
- example content answers and a zero-orphan check;
- a same-model before/after comparison.

It never recomputes content-level truth from `ev_raw` and never reports a content-view mismatch
count. It is also at commit `8af15cb`; current `sql/30`, `sql/40`, and `sql/80` have hundreds of
later changed lines. `WALKTHROUGH.md:158` accurately says the 6,764-row content reconcile has no
evidence file and predates relevant rewrites. The submission table should not override that honest
status by relabeling a different artifact.

### Finding L — several simple README claims are stale

**Severity: P2.**

**Locations.** `README.md:46-48,107-109,139`; `SUBMISSION.md:121,200`; `sql/00_schema.sql:43-45`.

- README says `ev_raw` is ordered by `(video_session_id, event_timestamp)`. Current source and live
  Cloud both use `(toStartOfHour(event_timestamp), platform, video_session_id, event_timestamp)`.
- README and SUBMISSION say 16 ADRs; there are 28 numbered ADR files.
- README says six dossier questions and SUBMISSION says five more after doubt 02; there are 12.

All 69 local Markdown links in the two documents resolve, so the issue is claim drift, not broken
navigation.

### Finding M — current live `ev_raw` is not the schema in current `main`

**Severity: P2 evidence-scope gap.**

**Locations.** `sql/00_schema.sql:15-61`; runtime `system.columns`; Q37 scratch evidence.

Current main declares `extra Map(...)` and no `ingested_at`. Live `sonyliv.ev_raw` has `ingested_at`
and no `extra`. The headline derivation does not read either column, so this does not explain or move
the five confirmed answers. It does mean that live headline verification is not a verification of
main's current unknown-dimension landing/schema path. That path is supported by Q37 scratch evidence,
not by the graded snapshot, and the distinction is absent from `SUBMISSION.md`'s "every number was
re-executed against the graded service" framing.

## 7. Claims with no current test, evidence, and owner

### Finding N — rolling/tumbling correctness is the cleanest unowned gap

**Severity: P1 because it is a shipped required serving feature; no headline impact shown.**

**Locations.** `README.md:58-67`; `WALKTHROUGH.md:159`; `sql/85_windows.sql`.

`WALKTHROUGH.md` states the exact gap: the remembered 5/15/60-minute brute-force comparison predates
ADR 0009 and ADR 0014, no evidence file exists, and no tool runs it. Current searches of `TODOS.md`
and `docs/WORKTREE_QUEUE.md` found no owner for a fresh raw/dense-curve oracle. The tie-determinism
artifact proves repeatability, not correctness; ClickStack screenshots prove rendering, not the
window arithmetic.

This is the most useful no-test/no-evidence/no-owner answer after 234 commits because a judge can
query it directly and every existing green gate can remain green if `sql/85_windows.sql` is wrong.

### Finding O — content correctness is similarly unowned, but currently overclaimed

**Severity: P1.**

**Locations.** `WALKTHROUGH.md:158`; `SUBMISSION.md:61`; `sql/80_content.sql`.

The repository has useful content artifacts (dictionary binding, orphan checks, rendered answers),
but no current raw-to-content concurrency oracle. No queue row owns one. Unlike the window gap, this
one is actively mislabeled as a zero-mismatch reconcile in the submission, so it should be withdrawn
or regenerated before judging.

### Finding P — decline `DISENGAGEMENT` is unvalidated but honestly labeled

**Severity: disclosed limitation, not an additional failure.**

**Locations.** `docs/DECLINE_ALERTING.md:195-230`; `TODOS.md:87-96`.

There is no observed positive disengagement episode, hence no evidence that the rule recognizes one.
The repository says exactly that, names the missing cohort, and does not tune thresholds to fabricate
a pass. This is the correct treatment of an uncovered optional class. It is not included in the
judge-facing known-limitations list, but its feature documentation is candid.

## 8. Validation performed

- `HEAD == origin/main == origin/dev == c642066`; clean worktree before report.
- Live schema discovery, sample, and `EXPLAIN indexes=1` completed.
- Raw independent answer derivation completed in compatible and spec modes.
- Raw Q34 derivation completed: 82 / +1 / 63.
- Raw session-independent peak query completed: 2,894 at 10:56.
- Live serving snapshot completed: 2,917 / 2,844 / 2,894 / 7,121,135 s.
- Live source-contract gate completed: 0 FAIL, 3 WARN classes.
- Live `sql/90_reconcile.sql` completed: 17,028 / 0 / max 0 / peak 2,917.
- Local scratch negative gate completed and scratch database removed.
- Q37/Q38 source/evidence lineage inspected; shell syntax checks passed.
- All local links in `README.md` and `SUBMISSION.md` resolve.
- Repository visibility confirmed `PRIVATE` through GitHub.

## 9. Plain answer

**Would I submit this now? No.**

**Single thing to fix first:** repair the judge-facing claim ledger in `README.md` and
`SUBMISSION.md` as one submission change — put Q35 (2,917 to 2,927, +5.0 h) and Q34 (82 filtered
violations) in the known-limitations section, and withdraw the unsupported content/window
correctness labels until current raw-oracle evidence exists. A correct 2,917 snapshot is not enough
if the document promising complete disclosure omits the only known alternative that changes it.
