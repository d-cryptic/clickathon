# PROMOTION — how a feature earns its way from `dev` onto `main`

> **Summary:** `main` is what a judge reads and what we submit. `dev` carries ~115 commits across 31
> feature merges that were reviewed **only by the orchestrator that briefed them** — self-review at
> one remove. This defines the second-level gate each feature passes **individually** before it
> reaches `main`: promoted in dependency order, one at a time, each re-validated against the live
> ClickHouse Cloud service, cross-checked by a **different LINEAGE** (Codex — see check 5; the
> original `claude-fable-5` wording was superseded on 2026-08-02), with its docs
> proven current. A blanket `dev → main` fast-forward is explicitly rejected — it would promote 31
> features on the strength of one decision. **Nothing lands on `main` that has not passed all six
> checks below with committed evidence.**

**Started:** 2026-08-02. Ledger at the bottom; update it in the same commit that promotes a feature.

---

## Incident 2026-08-02 — paused, rebuilt, resumed. Read this before trusting a green gate.

**Resolved.** Promotion is live again. Kept as a record because the failure mode is subtle and will
recur if the cause is forgotten.

**What happened.** The gate on `sonyliv` failed: 17,028 minutes compared, **970 mismatched**,
`max_abs_diff` 193, served concurrency inflated above truth. `session_intervals` read 33,900 against
a true 30,323 and `cc_minute_delta` 42,396 against 28,073.

**Cause.** `tools/publish-test.sh` cuts SQL extracts and runs them against a scratch database, but
many extracted statements are **unqualified**, so they resolved against the *connection's* default
database — `sonyliv`. **811 unqualified writes** landed there after 19:00 on 2026-08-01. The query
log shows the two forms side by side in the same run: `INSERT INTO sonyliv_pub.cc_publish_lease …`
next to a bare `INSERT INTO cc_publish_lease …`. Same database-resolution family as queue item
**Q33**, third location.

**Why it hid for a day.** `ev_raw` was untouched and the **peak still read 2,917**, so every
spot-check of the headline number passed. Only the full gate — which compares *every* minute rather
than the peak — could see it. Repeated identical count queries also appear to have been served from
cache, so re-checking the same number several times gave false reassurance.

**The lesson, and it is a gate rule now:** *the headline being right is not evidence that the model
is right.* A spot-check of peak, or of a row count, is not a substitute for the gate. Check 4 exists
precisely because it compares all 17,028 minutes.

**Recovery.** `ev_raw` was byte-intact (905,558 rows, 10,866 sessions, unchanged max timestamp), so an
operator-authorised `REBUILD_GRADED=yes` restored every tier exactly: 30,323 / 28,073 / 26,254 /
91,692, peak 2,917, gate **17,028 · 0 mismatched · max_abs_diff 0**. The same rebuild cleared the
ADR 0016 and ADR 0022 migration debt, so `v2.todo.md` §A3 is closed.

**Also found by it:** ADR 0022 added `cube_level` to `cc_hour_agg` but never added the migration step,
so the first authorised rebuild after it died at stage 4/6. `build-model.sh` now migrates that table
the same way it already migrated `cc_user_minute`.

## Why not just merge `dev`

`dev` contains all of `main`, so a fast-forward is *mechanically* clean and would take one command.
That is exactly the problem: it converts 31 independent judgements into one, and the reviewer for
every one of them was the same orchestrator that wrote the brief. Two real defects today were caught
only because something re-read the work afterwards — a wrong `6,600×` ratio that had already shipped
to `main`, and a `TARGET=cloud` flag that silently queried local. Both looked fine at merge time.

So: **one feature, one gate, one commit on `main`.**

## The six checks — all must pass, evidence committed

Per feature:

**1 · Isolate.** Identify the minimal set of commits that make the feature coherent. If it cannot be
separated from another feature, **say so in the ledger and promote the smallest coherent group** —
do not pretend to a granularity the code does not have. ADR 0016 genuinely depends on ADR 0013;
splitting them would ship a publisher that references phases that do not exist.

**2 · Build and test.** `make ci` green from a clean shell — lint, `go test -race`, build. Any SQL
the feature touches applies cleanly to a **scratch** database, never the graded one.

**3 · Run it for real.** Against the live ClickHouse Cloud service, **read-only**. Re-derive the
numbers the feature claims rather than trusting the ones in its commit message. A feature whose
claimed number cannot be reproduced does not promote — that is the whole point of this gate.

**4 · The correctness gate — two measurements, not one.** Revised 2026-08-02 after W1 refused twice
and was right both times.

**4a · The graded database passes the gate matching its DEPLOYED spec.** Currently that is `dev`'s
gate: **17,028 minutes · 0 mismatched · max_abs_diff 0 · peak 2,917**. This is the correctness
measurement — is the database right?

**4b · Run the promoting branch's OWN gate too, and account for any difference.** If it disagrees,
the difference must be explained as **known spec skew** with the commit that causes it named. Any
disagreement that cannot be attributed to a specific known change is a **failure**.

**Why this is stricter, not weaker.** The original wording assumed the graded database matched
`main`. It does not: the 2026-08-02 recovery rebuild ran `dev`'s build, so the graded database now
embodies `dev`'s spec — including ADR 0009's same-second resume fix (`>` → `>=`), which affects
**2,502 of 27,340 pauses (9.15%)**. `main`'s gate still carries the strict `>` and therefore reports
**177 mismatched, max_abs_diff 39** against a database that is *correct*. Running a stale gate
measures spec difference, not correctness — 4b now surfaces that as its own signal instead of
letting it masquerade as either a pass or a data fault.

**The orchestrator's error, recorded so the sequencing lesson survives:** rebuilding the graded
database from `dev` while promoting wave-by-wave from `main` put the deployed spec *ahead* of the
branch being promoted. Either the rebuild should have come from `main` plus the wave under
promotion, or wave 2 should have been promoted first. It could not have come from `main` — that
would have undone ADR 0009 and reintroduced a known bug — so the real consequence is below.

**Wave 2 is now on the critical path.** `main` currently ships SQL and docs that do not match the
deployed database. Until ADR 0009/0011/0014 are promoted, every wave-1-based branch will show 4b
skew, and `main` is not independently releasable in the sense this document requires. Promote wave 2
next, and do not let other waves overtake it.

**5 · Cross-model validation — by a different LINEAGE, not just a different checkpoint.** A **Codex**
agent (`--provider codex`) independently verifies the feature's claims against the live database and
the repo. Its brief is adversarial: *find the claim that does not hold.* Its verdict is committed
alongside the feature.

Codex rather than another Claude model deliberately: the failure this check exists to catch is a
**shared blind spot**, and two checkpoints of the same family share more of those than two families
do. Codex audits already found real defects here — the split-generation incident in
`docs/codex-validation/002.md` and four P0s in `003.md`, including the unguarded write path that
later corrupted the graded database.

**6 · Docs current.** Every doc the feature touches states what is true **after** it, and no doc
elsewhere contradicts it. This is the check that failed most often today: five files still asserted
"the publisher has zero references to `cc_hour_agg`" hours after that became false, two of them
contradicting themselves a few lines apart.

## Rules that hold throughout

- **The graded database is read-only during promotion.** `REBUILD_GRADED` and
  `APPLY_GRADED_DESTRUCTIVE` stay unset. Schema changes on `sonyliv` are an operator decision and
  are parked in [`v2.todo.md`](../v2.todo.md) §A3.
- **`main` must be releasable after every single promotion**, not only at the end. If a promotion
  leaves `main` in a state we would not submit, it was too big.
- **A failed check is a finding, not a blocker to route around.** Record it, fix it on a branch, and
  re-run the gate. Do not promote with a caveat.
- **Docs-only features still pass checks 5 and 6.** Most of today's real defects were wrong *claims*,
  not wrong code.

## Promotion order — dependencies decide it, not importance

Infrastructure that everything else assumes goes first; anything that changes a serving table's
shape goes last, because it is the hardest to reverse.

| Wave | Features | Why here |
|---|---|---|
| **1 · Foundations** | ADR 0018 target resolution + the `tools/ch` `TARGET` fix; the write guards on `build-model.sh`/`apply-sql.sh` | Every later validation runs *through* these. If `TARGET=cloud` silently means local, every check above is worthless. |
| **2 · Model correctness** | ADR 0009 determinism · ADR 0011 normalisation · ADR 0014 peak-minute ties | They change the answer; everything downstream is measured against it. |
| **3 · Serving + publication** | ADR 0013 finalizer · ADR 0016 four tiers (**one group — 0016 cannot stand alone**) | The largest behavioural change on `dev`. |
| **4 · Evidence and tooling** | benchmark bundle · `make ci` + tests · scale ladder · unseen-day runbook · demo harness · ClickStack dashboards | Read-only; each independently checkable. |
| **5 · Claims and dossiers** | scope-claims pass · the 11 `doubts/` dossiers · adversarial + liveness evidence · audits · queue | Docs-only, but checks 5 and 6 still apply. |
| **6 · Shape changes** | ADR 0021 projection (already live on the service) · ADR 0022 `cube_level` | Last: they alter a serving table's shape, and their migration is parked in `v2.todo.md` §A3. |

## Check-5 verdicts so far — both DO NOT PROMOTE, both correct

**W1 foundations — DO NOT PROMOTE.** `GRADED_DB` was caller-overridable, so
`GRADED_DB=anything` disabled both graded-database guards. Verified and fixed (`readonly`). The
validator also independently confirmed the check-4 attribution: replacing only the two strict `>`
predicates removes **all 177** mismatches, so the skew is entirely `0c0f020`. Second finding: ADR
0018's *"every layer"* claim overstates — several shell tools still fall back to a server default.

**W2 model correctness — DO NOT PROMOTE.** ADR 0009 is promoted claiming *"all seven dimensions leave
`any()`, determinism is end to end"*, and **the branch's own `sql/40_deltas.sql` disproves it**:
lines 87-89 still execute `any(platform)`, `any(country)`, `any(content_id)`. Verified — those are
executable, not commentary, and they collapse per-interval labels for 25 live sessions with multiple
interval platforms.

**Cause: an incomplete cherry-pick.** `dev` removed that `any()` in commit `df6e7a2` (*"the rebuild
owns every tier it invalidates, and the last any() leaves"*). W2 picked the ADR 0009 derivation fix
and **not** the follow-up that finished the job, so it promoted a claim its own tree contradicts.
Everything else in W2 held: both gates pass, ADR 0011's UDFs and the 1,774 → 2,196 Hindi pair are
live, ADR 0014 agrees 98/98 hours with no bare live-view `argMax`.

**The lesson for every remaining wave:** a cherry-picked feature is not the ADR that introduced it.
Isolation (check 1) must include the follow-up commits that make the ADR's claims true — grep the
promoted tree for what the ADR *says* is gone, rather than trusting the ADR.

### Both verdicts answered — 2026-08-02, awaiting a fresh check 5

Neither branch merges on the strength of these answers. A **new** Codex pass runs first, because
these are the two branches that already failed one.

**W2 — answered, and 4b now passes with no excuse.**
[`evidence/promotion/w2/codex-check5-answers.md`](../evidence/promotion/w2/codex-check5-answers.md).
`df6e7a2`'s `sql/40_deltas.sql` blob cherry-picked, so ADR 0009's title is now true of the tree. Not
asserted — measured: two local scratch rebuilds differing only in that file put the pre-fix branch at
ANDROID_PHONE **16,357** rows against the deployed **16,366**, and the post-fix branch byte-identical
to live across all ten platforms, with `sum(delta)` unmoved in every build. All three tier counts now
equal the graded database (**30,323 / 28,073 / 26,254**); before, two of the three did not. Gates
re-run read-only: **4a PASS, 4b PASS**, both 17,028 · 0 · 0 · peak 2,917. The three documentation
findings are closed too — ADR 0009's self-contradiction, the 2,697-vs-2,502 numerator, and
`RUNBOOK_UNSEEN.md`'s first seven lines, which described a gate defect commit `81c0161` had already
fixed. ADR 0014's inventory row 12 was applied from the ADR's own diff sketch while the file was open.

**W1 — answered.**
`evidence/promotion/w1/codex-check5-answers.md` (lands with W1; not on this branch).
`06a720d`'s guard hardening cherry-picked (`readonly GRADED_DB`, broadened destructive-form grep), and
ADR 0018's *"every layer"* claim narrowed to the layers that actually hold, with the enumeration of
which tools do and do not.

**Applied to both, as the rule now demands:** every ADR on each branch was grepped against the
promoted tree for what it says is gone. That is how row 12 of ADR 0014 surfaced — disclosed in prose,
unapplied in code, in a file the branch carried.

## Ledger

`—` not started · `WIP` in a promotion worktree · `GATE n` failed at check n ·
`GATE 5 → ANSWERED` findings closed with evidence, awaiting a **fresh** check 5 · `✓` on `main`

| Wave | Feature | Status | Evidence |
|---|---|---|---|
| 1 | ADR 0018 target resolution + `tools/ch` | `GATE 5 → ANSWERED` | `w1/codex-check5-answers.md` (lands with W1) — "every layer" narrowed to the layers that hold, with the per-tool enumeration |
| 1 | write guards on the graded database | `GATE 5 → ANSWERED` | `w1/codex-check5-answers.md` (lands with W1) — `readonly GRADED_DB` (`06a720d`) so the guard's subject is not caller-controlled; destructive-form grep broadened. Refusals tested, never overrides |
| 2 | ADR 0009 interval-delta determinism | `GATE 5 → ANSWERED` | [`w2/`](../evidence/promotion/w2/codex-check5-answers.md) — `sql/40_deltas.sql` cherry-picked; before/after scratch rebuilds prove the label collapse was executable (16,357 → 16,366 ANDROID_PHONE rows) and that the fix reproduces the deployed labels exactly. 4b PASS, no skew |
| 2 | ADR 0011 query-time normalisation | `GATE 5 → ANSWERED` | [`w2/`](../evidence/promotion/w2/codex-check5-answers.md) — held under check 5 unchanged: 5 UDFs + 4 views live, Hindi pair **1,774 → 2,196** reproduced |
| 2 | ADR 0014 peak-minute tie-break | `GATE 5 → ANSWERED` | [`w2/`](../evidence/promotion/w2/codex-check5-answers.md) — 98/98 hours held; inventory row 12 (`sql/90_reconcile.sql`) **applied** from the ADR's own sketch, verdict-neutral; rows 10–11 (`tools/unseen-run.sh`) named as open, file not carried |
| 3 | ADR 0013 + 0016 publication (one group) | — | |
| 4 | benchmark evidence bundle | — | |
| 4 | `make ci` + the Go test suites | — | |
| 4 | scale ladder (ADR 0020) | — | |
| 4 | unseen-day runbook + tools | — | |
| 4 | demo harness | — | |
| 4 | ClickStack dashboards (7 / 53 tiles) | — | |
| 5 | scope-claims + `doubts/` + audits | — | |
| 6 | ADR 0021 projection | — | |
| 6 | ADR 0022 `cube_level` | — | |
