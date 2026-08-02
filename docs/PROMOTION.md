# PROMOTION — how a feature earns its way from `dev` onto `main`

> **Summary:** `main` is what a judge reads and what we submit. `dev` carries ~115 commits across 31
> feature merges that were reviewed **only by the orchestrator that briefed them** — self-review at
> one remove. This defines the second-level gate each feature passes **individually** before it
> reaches `main`: promoted in dependency order, one at a time, each re-validated against the live
> ClickHouse Cloud service, cross-checked by a **different model** (`claude-fable-5`), with its docs
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

## ⚠ The waves are SEQUENTIAL. Do not run them in parallel — measured, 2026-08-02.

The orchestrator spawned W1, W2 and W3 concurrently to save wall-clock. W3's check-1 analysis proved
that cannot work, with three concrete dependencies:

```
 W1  tooling   apply-sql.sh --database parser · env-capture · the write guards
       │
       ▼
 W2  model     sql/15_normalise.sql (ADR 0011) · 0009 · 0014
       │
       ▼
 W3  publication  needs BOTH: the parser to install into scratch, normalise to build at all
```

W3 could not run check 3 **at all** — not "ran and failed", could not run — because `main`'s
`apply-sql.sh` has no option parser, so its convergence claim was unverifiable. A promotion that
cannot execute a check has failed check 1, and parallelism is what produced that state.

**W3 is parked**, its cherry-picks and dependency analysis pushed to
`chore/promotion-w3-publication`. It re-runs after W1 and W2 are on `main` — not before.

**The general rule:** promote one wave, land it on `main`, then start the next. The wall-clock saving
from parallel waves is illusory when each later wave has to be thrown away and re-derived.

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

## W3 refused at check 1 — the wave order is a real dependency, not a preference

W3 (publication) cherry-picked ADR 0013+0016+0019 onto `main`, verified all three named risk checks
against the **promoted tree rather than the ADR prose** — `mv_user_minute` has no surviving
`CREATE MATERIALIZED VIEW`, `cc_user_minute` is `ReplacingMergeTree(computed_at)`, all 20 write
statements in `publish-test.sh` are qualified — and then **refused at check 1** on three
wave-1/wave-2 dependencies:

| | dependency | consequence on `main` |
|---|---|---|
| **D1** | `publish-test.sh` calls `apply-sql.sh --database`; `main`'s copy has **no option parser** | the convergence claim cannot be re-derived, so check 3 never ran |
| **D2** | `main`'s `apply-sql.sh` sources `.env` *after* the caller's environment | **there is no route on `main` that installs `sql/12_publish.sql` anywhere but the graded database.** Same Q33 family as the 2026-08-02 incident |
| **D3** | ADR 0016's `build-model.sh` applies `sql/15_normalise.sql` (ADR 0011, wave 2), absent on `main` | `make model` is broken |

**D2 is the one to sit with.** It is not a promotion problem — it is a property of `main` as it
stands today: the only place the publisher can be installed is the database we are scored on. That is
exactly the shape of the incident that already happened once.

**It also corrected an attribution that two prior reviews had agreed on.** W1 and Codex both
concluded "two characters (`>` → `>=`) account for all 177 mismatches". W3 re-verified rather than
trusting either, and found `main`'s gate differs from `dev`'s in **three** places — the two resume
predicates **plus a zero-length-window `arrayFilter`**. Patching only the two still takes the branch
gate to 0/0/2,917, so the attribution's *conclusion* holds — but the third difference is real, and it
is the zero-length-segment handling that queue item **Q35** is about (182 runs, peak 2,917 → 2,927).
Two independent reviews had said "two" and the number was three.

**The lesson, now a rule:** a promotion that *cannot run* a check is a check-1 failure, not a pass
with a caveat. And an attribution agreed by two reviews is still worth re-deriving — "two characters"
was very nearly right, and very nearly is how a third difference stays invisible.

## W1 rejected a second time — one finding fixed, one scoped, one my own brief's fault

**The scanner gap is real and is an accident risk.** It missed **`DELETE FROM`** — ClickHouse's
lightweight delete, ordinary SQL that nobody thinks of as an `ALTER` — plus `OPTIMIZE`,
`MOVE PARTITION`, `REPLACE PARTITION`, `MATERIALIZE TTL` and `MODIFY COLUMN`. Fixed; `DELETE FROM` is
the one that would have bitten, because it is the form a person writes without noticing it is
destructive.

**The exported-function and conditional-source bypasses are real but out of threat model.** They
require someone to deliberately export a shell function shadowing a command the guard depends on.
These guards exist to stop **accidents** — a stale base, a mistyped target, a scrolled-past banner —
not a determined operator. Recording that scope explicitly rather than hardening against an attacker
we do not have: an unbounded guard is one people route around. Anyone who disagrees should say so in
an ADR, not silently widen the check.

**Check 4b's failure is my brief's fault, not W1's.** The re-validation brief was generated from
W2's by substitution and carried W2's wording — *"any mismatch is a failure"*. That is right for W2,
which carries ADR 0009. W1 does not, so its 177-mismatch spec skew is **expected and already
attributed** to `0c0f020`, exactly as W1's own earlier analysis proved by isolation. Codex applied
the brief it was given, correctly. **A generated brief inherits assumptions that do not transfer** —
the same class of error as the incomplete cherry-picks, one level up.

**What survived:** ADR 0011's five UDFs, four views and the 1,774 → 2,196 Hindi pair; ADR 0014's
98/98 hours with no bare live-view `argMax`; the 2,887 → 2,917 and 1,949.3 → 1,978.1 h headline; and
ADR 0018's "every layer" claim now explicitly withdrawn and replaced with a measured per-layer table.

## 🔴 Wave A rejected — and it settles the wave question for good

Codex validated the first file-state promotion and found three things. Two are fixed; the third
changes the plan.

**1 · A newline defeated every destructive-SQL pattern — including plain `DROP`.** Ordinary DDL
formatting evades a line-oriented grep:

```sql
DROP
  TABLE ev_raw;
```

The guard looked thorough and caught **nothing that spanned a line break**, which is how most people
write DDL. Fixed: comments stripped, all whitespace collapsed, matched against one flat stream.
Re-tested — `DROP`, `DELETE FROM` and `ALTER … DROP COLUMN` split across lines are all caught, and
benign SQL still passes.

**2 · The file-state-copy claim did not hold for one file.** Nine of ten were byte-identical to
`dev`; `tools/load.sh` differed by 353 insertions. Cause: I copied at time T and `dev` moved —
Y1's landing table and my own `--replace` guard both landed afterwards. **A copy is only as good as
its timestamp**, so a wave must be rebuilt from `dev` immediately before validation, not once at
the start.

**3 · Tooling is NOT separable from SQL, and this is the structural finding.** The promoted
`tools/build-model.sh` unconditionally applies `sql/15_normalise.sql`, which wave A does not carry;
`dev`'s loader requires `sql/05_landing.sql`, likewise absent. **Wave A alone is not a runnable
state.**

### So the partition question is now closed, in both directions

- **By ADR** — impossible: `sql/50_hour_agg.sql` implements 0003, 0006, 0014, 0016 and 0022.
- **By file** — impossible: `tools/` executes `sql/`, so a tooling wave without its SQL cannot run.

**`tools/` and `sql/` promote together or not at all.** That is not a retreat to the wholesale merge:
it is one validated increment containing the model and the tooling that runs it, with evidence, docs
and the Go layer following as genuinely separable waves. The candidate branches `promo/w12-fileset`
and `promo/waveB-model` should be combined and re-validated as one.

**Check 6 also failed:** `docs/RUNBOOK_UNSEEN.md` still says the caller environment is ignored, which
contradicts all four promoted environment-capture scripts.

**What held:** `make ci`, all four target-resolution probes, both ordinary graded guards, check 4a at
17,028 / 0 / 0 / 2,917, and the expected 4b skew.

## ✅ The method changes: promote FILES to `dev`'s state, not COMMITS onto `main`

All three rejections share one cause, and it is the method rather than the agents.

**Cherry-picking commits onto `main` reconstructs a state by hand**, and hand-reconstruction misses
the follow-ups: `df6e7a2` for ADR 0009, the `build-model.sh` step for ADR 0011, 230 lines of
`unseen-run.sh` for ADR 0014, wave-1 tooling for W3. Every miss produced a branch where the ADR's
claim was false — and a green gate, because the gate does not check ADR prose.

**The fix is to stop reconstructing.** For a wave, take **`dev`'s version of every file the wave
owns**, wholesale:

```bash
git checkout dev -- sql/30_build_intervals.sql sql/90_reconcile.sql sql/15_normalise.sql \
                    sql/50_hour_agg.sql sql/85_windows.sql tools/build-model.sh …
```

`dev` is the state in which those ADRs' claims are **true and gate-green**. Copying that state cannot
produce a branch where an ADR contradicts its own tree — the failure mode that rejected three
attempts.

**This keeps everything the second level was for.** The wave is still one coherent feature group; the
six checks still run; Codex still validates independently; `main` is still built up deliberately
rather than fast-forwarded in one unexamined jump. What changes is only *how the branch reaches the
state being validated* — by copy rather than by reconstruction.

**What it gives up, stated honestly:** commit-level provenance on `main`. A wave lands as one commit
per feature group rather than replaying `dev`'s history. That is a real loss for `git blame`, and it
is worth it — `dev`'s history remains intact and is where anyone should look.

**The file list per wave must still be derived, not guessed.** Use
`git diff --name-only main..dev -- sql/ tools/` and assign every file to exactly one wave. A file in
no wave never reaches `main`; a file in two waves is a conflict waiting to happen.

## 🔴 Three rejections, three incomplete cherry-picks — this is now THE failure mode

W2's **second** rejection has the same root cause as its first, and W3's was a variant. That makes it
a pattern rather than an accident, and check 1 must change to catch it.

| attempt | what was picked | what was NOT, and the consequence |
|---|---|---|
| W2 #1 | ADR 0009's derivation fix | `df6e7a2`'s `sql/40_deltas.sql` — so the ADR's own `any()` claim was false on its branch |
| W2 #2 | ADR 0014's `50_hour_agg.sql` tie-break | `tools/unseen-run.sh` — **230 lines** different from `dev`. Codex ran it: the unseen-day submission path returns **16:59 and 16:35 instead of 15:51** |
| W2 #2 | ADR 0011's `sql/15_normalise.sql` | the `build-model.sh` step that applies it — `make model` never runs it, so the promoted ADR "did nothing" |
| W3 | ADR 0013+0016 | wave-1 tooling — check 3 could not run at all |

**W2 #2 is the most serious defect any review has found**, because `tools/unseen-run.sh` is *the
unseen-day submission path*. A promoted W2 would have shipped a `main` that answers the peak-minute
question **wrongly on the day it counts most**, while every gate stayed green — the gate compares
concurrency, not peak-minute attribution.

Codex also caught the docs half: ADR 0011 says both three and four views; the unseen runbook calls
**both 16:59 and 15:51** the expected good answer; ADR 0014 is marked Accepted while its submitted
answer path is explicitly open.

### The rule check 1 now carries

**A feature is the ADR plus every commit that makes the ADR's claims true.** Before promoting:

1. `git log --oneline --all -S'<the thing the ADR says is gone>' -- <file>` for each claim.
2. Diff **every file the ADR names** between the branch and `dev` — not just the one the ADR
   headlines. `unseen-run.sh` differed by 230 lines and nobody looked.
3. **Run the path the ADR governs**, not just the gate. Three green gates hid all three of these.

## ✅ RESOLVED 2026-08-02 — operator authorised the fallback; `main` carries the whole system

Seven promotion attempts, **seven rejections**, every one correct. The operator took the documented
fallback in [`PROMOTION_FALLBACK.md`](PROMOTION_FALLBACK.md) rather than continue wave-by-wave.

**The gate was not wasted — it is the reason this merge is safe.** Each rejection produced a
structural fix that is now on `main`:

| rejection | what it caught |
|---|---|
| W1 ×2 | `GRADED_DB` caller-overridable → both graded guards defeatable |
| W2 ×2 | ADR 0009's `any()` claim false on its own tree; `unseen-run.sh` returning **16:59 where earliest-wins requires 15:51** — the submission path, wrong, with every gate green |
| W3 | could not *run* check 3; `main` had no route to install the publisher anywhere but the graded database |
| core ×2 | a newline defeated every destructive pattern; then CRLF and `/* */`; `87_viz.sql` reading production's catalog; the source-contract gate shipping without its SQL |

**None of those would have surfaced from a merge alone**, and all are fixed in what was merged.

**What this ledger now means.** `main` and `dev` are identical. The six checks stop being a promotion
gate and become a **regression gate**: run them against `main` before submission, and against any
change to it. The distinction between "checks I ran" and "independently validated" still holds — and
independent validation of `main` as a whole is now the outstanding work.

## Ledger

`—` not started · `WIP` in a promotion worktree · `GATE n` failed at check n · `✓` on `main`

| Wave | Feature | Status | Evidence |
|---|---|---|---|
| 1 | ADR 0018 target resolution + `tools/ch` | — | |
| 1 | write guards on the graded database | — | |
| 2 | ADR 0009 interval-delta determinism | — | |
| 2 | ADR 0011 query-time normalisation | — | |
| 2 | ADR 0014 peak-minute tie-break | — | |
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
