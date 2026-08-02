# Codex 004 — triage: the preprocessing boundary, against what has since landed

> **Historical audit:** predates the official unseen release and upstream `c1e1c69`; current
> terminology and readiness live in Codex Validation 009.

> **Summary:** Codex 004 audits commit `9c26918` and says keep the system ClickHouse-first, add an
> immutable all-`String` landing table, and wire `v_ev_model_input` into both the builder and the gate.
> Most of its architecture advice is **already implemented** — `extra Map` (ADR 0024), quarantine
> (ADR 0025), the source-contract gate (ADR 0026) and query-time `dictGet` content enrichment all
> predate it. Its **two "mandatory corrections" are real, and both were already documented as known
> gaps by T3 in `docs/PREPROCESSING.md`** — corroboration by a second method, not a new discovery.
> **Neither is owned by any branch.** I measured the load-failure claim: it is **true, loud, and
> incomplete** — one bad value costs all 905,558 rows (exit 27), but three other malformations parse
> *silently* and corrupt the model instead, which is the worse half 004 did not find.

**Triaged:** 2026-08-02, against `dev` at `594989e` after merging `origin/dev`. Codex audited
`9c26918`; ten commits have landed since. Measurements below were run on the **local** container
(ClickHouse 26.7.1.1315) in scratch database `t004_probe`, now dropped. No Cloud writes.

> ⚠️ **`docs/codex-validation/004.md` is not committed to any branch.** It exists only as an
> untracked file in the main checkout (`~/Developers/personal/clickathon-project/`). `001`–`003` are
> committed; `004` is one `git clean` from gone. Committing it is outside this branch's ownership —
> **an operator should land it on `dev` alongside this triage.**

---

## A · Already implemented — 004 audited a commit that predates the work, or missed what exists

| 004 finding | Status |
|---|---|
| §2.2 keep `extra Map` for unforeseen flat columns, don't swap to JSON yet | **ADR 0024**, merged. 004 is confirming our choice, not proposing one |
| §2.3 content enrichment must respect MV trigger direction — join at query time, don't assume an MV cascade | **Already done.** `sql/80_content.sql` resolves title/video_type/category by `dictGet` at query time; neither MV (`mv_stateless`, `mv_session_dirty`) joins `content_dim` |
| §2.1 quarantine policy: reject nothing, quarantine only unusable, keep-and-count suspicious, normalise on read | **ADR 0025**, merged — 004 explicitly calls it "otherwise sound" |
| §4 source-contract validation as a read-only FAIL/WARN/INFO gate | **ADR 0026**, merged (T9) |
| §4 header drift: new columns announced and carried, missing required columns refuse before load | **ADR 0024** in `tools/load.sh` — verified: `NEVER_DEFAULT` refuses missing `event_timestamp`/`video_session_id` with no override flag |
| §1.1 "the loader already uses Python's `csv` module for header inspection — that is appropriate" | Description of current state, not a request |
| §3 an incremental MV cannot be the sessionizer; keep MV-marks-dirty + stateful finalizer | **ADR 0004/0005/0013.** This is 004 arriving at our design, see §F |
| §1.2 no foreground/gap/session logic in the adapter | We already comply — every model rule is SQL |

## B · Independently corroborated — 004 reached our own conclusions by a different route

This is where 004 earns its keep, and it is a stronger result than either finding alone: **004 is an
architecture review that ran nothing; T3's `docs/PREPROCESSING.md` is an implementation report that
ran everything. They independently name the same two gaps, in the same order.**

| 004 finding | Our independent finding |
|---|---|
| §4.1.1 "the current typed `input()` path can reject a whole batch because one value cannot parse" | [`docs/PREPROCESSING.md`](../PREPROCESSING.md) §Known gaps **1**, written by T3 before 004: "A type-mismatched row still fails the whole load batch… rejects the batch, not the row" |
| §4.1.2 "`sql/30_build_intervals.sql` and three reads in `sql/90_reconcile.sql` still use `ev_raw`, while `v_ev_model_input` exists but is not enforced" | [`docs/PREPROCESSING.md`](../PREPROCESSING.md) §Known gaps **2**, and the comment block at `sql/15_normalise.sql:550-557` which says "NOT WIRED" in the source itself |
| §6 `feat/problem-space-research` is ideas, not mergeable code | [`docs/design-bakeoff.md`](../design-bakeoff.md) reached **REJECT wholesale adoption, confidence HIGH (~90%)** on 2026-08-01 — a day earlier, from the git diff, never having checked the branch out |
| §6.4 the research branch's state-gated model reads ~10.9% below the incumbent, and that delta is a mentor question not a verdict | Bake-off measured **~11% below on watch-time** and reached the same "this is dossier evidence, not organiser semantics" conclusion |

**004's §4.1.2 line count is exactly right.** `sql/30_build_intervals.sql:135` reads `FROM ev_raw`;
`sql/90_reconcile.sql` reads `ev_raw` at lines **59, 92 and 172** — "three reads", as claimed.

## C · In flight now — owned, not yet merged

**Nothing in 004 is owned by a running branch.** I checked all ten active worktrees
(`w1-biz-which-sessions-count`, `concurrency-decline-alerting`, `publisher-state-machine-safety`,
`promotion-w1-w2`, `u2-gb-scale`, `t7-replay-demo`, `promotion-w1-resume`, `v2-tuned-constants`,
`u3-point-in-time`, `v3-live-intervals`) with
`git diff --name-only origin/dev...<branch>` filtered to `load.sh`, `30_build_intervals.sql`,
`90_reconcile.sql`, `15_normalise.sql`: **zero hits.** Both mandatory corrections are unowned.

The one adjacent item: 004 §5 lists lateness/finality as incomplete. That is already the single open
decision in [`docs/DESIGN_DECISIONS.md`](../DESIGN_DECISIONS.md) ("three decided; **lateness is the
open one**") and a mentor question, not an engineering gap. No new owner needed.

---

## D · Genuinely new and unowned — sized

### D1 · The load-failure blast radius, **measured** — the one 004 asked us to size

004 §4.1.1 states the risk in one sentence. I ran it. **It is true, it is loud, and 004 found only
half of it.**

**Test:** the real 905,558-row file, exactly one value corrupted — data row 499,999,
`event_timestamp` `1785063241252` → `NOT_A_TIMESTAMP`. Loaded via `tools/load.sh --database
t004_probe` on the local container, i.e. the committed loader with ADR 0024 and ADR 0025 in place.

**Result:**

```
Code: 27. DB::Exception: Cannot parse input … (at row 500000)
  Column 5, name: event_timestamp, type: UInt64, ERROR: text "NOT_A_TIME" is not like UInt64
  (CANNOT_PARSE_INPUT_ASSERTION_FAILED)

exit code                27
ev_raw after             0        rows   (of 905,558)
content_dim after   33,464        rows   ← loaded, because it inserts FIRST
retry with the good file:  REFUSED — "t004_probe already holds data and INSERT APPENDS"
```

Three things follow, and only the first is in 004:

1. **One value costs the entire file.** 905,558 → 0.
2. **The failure is loud, and the guard holds.** Exit 27, `set -e` aborts, and the refuse-guard then
   blocks a naive retry from doubling. This is a *much* better failure mode than the silent
   double-load of bug 8. 004 does not credit it.
3. **The two tables are left inconsistent.** `content_dim` inserts before `ev_raw` (`load.sh:437`
   then `:440`), so a failed load leaves 33,464 content rows and 0 event rows. Recovery on the unseen
   day is `--replace`, not a bare re-run — and `--replace` is the destructive flag. Nobody had
   written this down.

**Quarantine cannot help here, and this is structural.** `q_reason(sid, uid, ts)`
(`sql/15_normalise.sql:393`) takes an *already-typed* `DateTime64(3)`. It is a rule over rows that
are already in `ev_raw`. A row that fails `input()` never reaches `ev_raw`, so no ADR-0025 reason
code can ever fire on it. **T3's quarantine does not and cannot cover this** — confirming, not
contradicting, T3's own §Known gaps 1.

**The half 004 missed.** I swept six malformations of the same column. Only three hard-fail; the
other three **parse cleanly and corrupt the answer**:

| malformed `event_timestamp` | exit | rows loaded | becomes | verdict |
|---|---:|---:|---|---|
| `NOT_A_TIMESTAMP` | 27 | **0** | — | hard fail, whole file lost |
| `-1` | 72 | **0** | — | hard fail, whole file lost |
| `1785063241252.7` (decimal) | 27 | **0** | — | hard fail, whole file lost |
| `""` (empty) | 0 | all | `1970-01-01 00:00:00` | **silent** — loads as 0 |
| `1785063241` (seconds, not ms) | 0 | all | `1970-01-21 15:51:03` | **silent** — the T2 hazard exactly |
| `999999999999999999999999` | 0 | all | `9999-12-31 23:59:59` | **silent** — saturates |
| `"1785063241252"` (quoted) | 0 | all | correct | tolerated correctly, no issue |

**The silent class is the dangerous one, and it is precisely what §4.1.2 would fix.** Each of the
three silent rows lands exactly **1 row outside `[2020, 2035)`** — measured — which is exactly ADR
0025's `ts_out_of_range` quarantine rule. So:

> **The two 004 corrections are not independent. Wiring `v_ev_model_input` (D2) is what converts the
> silent-corruption class from "reaches the model" to "quarantined and counted". Tolerant landing
> (D1) is what converts the hard-fail class into that same already-solved path.** Do them together
> or the fix is half a fix.

**Size:** the full §2.1 recipe — immutable `ev_landing`, ingest metadata, batch manifest, provable
one-terminal-disposition-per-row — is **a day of work and a new table on the graded schema**. See §E1
for a cheaper version that buys the unseen day. **Severity: high** for the unseen day; **zero today**
(the provided file quarantines zero rows and parses clean, verified byte-identical in
`evidence/preprocessing.txt`).

### D2 · Wire `v_ev_model_input` into the builder and the gate — together

004 §4.1.2, corroborated in §B. Still true at `dev` HEAD. The diff is already written in ADR 0025
§Wiring: two `FROM ev_raw` → `FROM v_ev_model_input` in `sql/30_build_intervals.sql`, three in
`sql/90_reconcile.sql`.

**Why it must be atomic** (both 004 and `sql/15_normalise.sql:552-556` say this, and they are right): a
model that skips a row the gate still counts is a mismatch the gate will correctly fail on. One file
without the other turns a green gate red for the wrong reason.

**Size: small — under an hour**, five line-edits plus a reconcile run. **Exposure today: zero** —
on the provided file `q_reason` quarantines no rows, so `v_ev_model_input` *is* `ev_raw`, verified
row-for-row in `docs/PREPROCESSING.md`. It is pure unseen-day insurance, which is exactly why it
keeps not getting done. **Recommend doing it anyway**: it is the cheapest item on this page and it is
load-bearing for D1.

### D3 · A failed load leaves `content_dim` populated and `ev_raw` empty

Falls out of D1 but is separable and much smaller. `load.sh` inserts `content_dim` first, so any
`ev_raw` parse failure leaves a half-loaded database whose only documented recovery is `--replace`.
**Size: small.** Either insert `ev_raw` first (so the expensive, fragile one fails before anything is
written), or say so explicitly in `docs/RUNBOOK_UNSEEN.md`. The runbook is the cheaper fix and the
unseen day is when it matters.

---

## E · Where we should push back, or scope

### E1 · §2.1's landing table is right in principle and too big for the deadline

004 wants `ev_landing` — every source value as `String`, ingest metadata, a batch manifest that
proves every landing row reached exactly one terminal disposition. That is the correct long-term
design and I would not argue against it in a code review.

**But there is a version worth ~90% of it for ~5% of the work**, and 004 did not consider it because
it never ran the loader. The hard-fail class comes entirely from six typed fields in the `input()`
structure at `load.sh:440`. Declaring the fragile ones as `String` in `input()` and casting in the
`SELECT` with `accurateCastOrNull` moves the failure from *parse time* (fatal, whole file) to *cast
time* (a `NULL`, one row) — and a NULL timestamp lands outside `[2020, 2035)`, which is **already**
`ts_out_of_range` in ADR 0025. No new table, no manifest, no schema change on the graded database.

That is the same three-way split 004 asks for, reusing the classifier T3 already built and measured.
**Recommend: do the cheap version before the unseen day; record `ev_landing` as the post-deadline
design in ADR 0025 §Consequences, where the recipe already lives.** Do not build a landing table and
a manifest under deadline for a file that currently quarantines zero rows.

### E2 · §1.1's ingest metadata is not free on this schema

004 wants `ingest_batch_id`, source object key, source checksum and row number attached at ingest.
Reasonable for a streaming system. Here it means **adding columns to `ev_raw` on the graded
database** — and per `docs/GRADED_INVENTORY.md` the graded `ev_raw` has already drifted once
(a 14th column `ingested_at` ALTERed in by a rejected branch). We already have batch-level identity:
the refuse-guard, fresh dedup tokens per publish run, and `build_version`. **Scope: not before the
deadline**, and if it is done, not by touching the graded table.

### E3 · §1 answers a question nobody in this repo asked

004's headline decision is "do not introduce a Python/pandas pipeline that owns cleaning,
sessionization, foreground state, gaps, dedup or concurrency." Correct — and we never proposed one.
Every model rule is SQL; the Python in `load.sh` is header inspection and nothing else. §1, §7 and
half of §8 are a defence against a design that does not exist.

That is not wasted: it is a clean, citable statement of why the boundary sits where it does, and it
belongs in the design narrative for a judge who asks "why no Spark?". **Treat §1/§7 as submission
prose, not as a work item.**

### E4 · §4's "Foreground/heartbeat semantics: Unconfirmed" is right but not actionable here

004 marks the semantics row **Unconfirmed** and says private truth is unavailable. True, and already
the subject of nine dossiers in [`doubts/`](../../doubts/) carrying measured costs — `09` at −14.1%,
`02` at 9.7%. 004 adds no new measurement to that question. **No action: it is already the top of the
mentor list**, and 003-triage §E already warns against sending an unranked seventeen-question list.

---

## F · What 004 confirms, which is worth as much as what it criticises

Two external confirmations arrived by different routes and both matter for the submission:

1. **§3 rejects incremental-MV sessionization from first principles** — the late-bridging-heartbeat
   example (10:00, 10:04, then a late 10:02 merging two runs into one) is exactly the case ADR
   0004/0005 declined the obvious design over. 004 derives our MV-marks-dirty + stateful-finalizer +
   correction-by-diff split independently, citing the vendored `decision-late-arriving-upserts` rule.
   That is a second reviewer arriving at our architecture, and it belongs in `SUBMISSION.md` §4
   beside the §6-matrix confirmation that 003 already earned.
2. **§6 agrees with `docs/design-bakeoff.md` on `feat/problem-space-research`** — reject wholesale,
   cherry-pick the source-contract gate, the single-writer doctrine, the correction algebra, the
   watermark model and peak non-additivity. Two adjudications, a day apart, from different evidence
   (bake-off from the git diff; 004 from the architecture). The branch has sat idle in
   `docs/WORKTREE_QUEUE.md` marked "needs a human call" — **it now has two independent rejections and
   the human call is cheap to make.**

004's §8 verdict table also ratifies nine of our ten standing architecture decisions. The only row it
marks as needing work is the landing table, which is D1.

---

## What should become queue items

| # | Item | Size | Severity | Note |
|---|---|---|---|---|
| **1** | Wire `v_ev_model_input` into `sql/30_build_intervals.sql` + `sql/90_reconcile.sql`, atomically (**D2**) | < 1 h | high on the unseen day, zero today | Diff already written in ADR 0025 §Wiring. Cheapest item here and D1 depends on it |
| **2** | Tolerant load: `String` in `input()` + `accurateCastOrNull` in the SELECT (**D1**, scoped per **E1**) | ~2 h | high on the unseen day | Reuses ADR 0025's classifier; no new table, no graded-schema change |
| **3** | Document the half-loaded recovery path in `docs/RUNBOOK_UNSEEN.md` (**D3**) | 15 min | medium | A failed load leaves `content_dim` full, `ev_raw` empty; recovery is `--replace` |
| **4** | Commit `docs/codex-validation/004.md` to `dev` | 5 min | — | It is untracked in the main checkout only; `001`–`003` are committed |
| **5** | Make the human call on `feat/problem-space-research` | — | — | Two independent rejections now (§F2); it has been idle in the queue |
| — | `ev_landing` + batch manifest | ~1 day | — | **Post-deadline.** Record in ADR 0025 §Consequences, do not build now (**E1**) |

## What I could not verify, and why

- **§2.2's `+0.48%` / `+3.6%` compressed-size figures for `extra Map`.** Taken from ADR 0024; I did
  not re-measure. Not load-bearing for any verdict above.
- **§6's per-feature verdicts on `feat/problem-space-research`** (watermarks, `event_id`,
  `session_incarnation_id`, `player_instance_id`, …). I did not check the branch out — it is 9
  unmerged commits and outside this triage's ownership. I relied on `docs/design-bakeoff.md`, which
  adjudicated it from the diff and agrees at the headline level; the feature-by-feature rows in §6.2
  and §6.3 are **unverified by me**.
- **§6.4's "approximately 10.9% less foreground watch time"** for the research implementation.
  Bake-off independently measured "~11% below on watch-time"; the two agree, but I re-ran neither.
- **Whether the hard-fail classes behave identically on ClickHouse Cloud.** Everything above was
  measured on the local container (26.7.1.1315). The graded target runs Cloud 26.2.1.525 and the
  `input()` parse path is server-side and version-sensitive. The mechanism (typed `input()` structure)
  is identical in the statement `load.sh` sends to both, so I expect no divergence — but I did not
  test against Cloud, because doing so would mean writing to a Cloud database.
