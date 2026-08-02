# HANDOFF — read this first when you wake

> **Summary:** The official unseen data and submission contract are now released. The old “private
> repo” and “Team Captain” blockers below were not official requirements and are retired. What a
> human must still finish is the hosted demo, 2–3 minute video, final pitch PDF, self-contained team
> folder/PR and live ClickStack evidence. The ClickStack update also requires committed deployment
> and OTel wiring, redacted environment example, named destination service/tables, README captures,
> and a live walkthrough; screenshots alone are insufficient. The portal closes automatically at
> **12:00 PM IST on 2026-08-02**. Use Codex Validation 009 for current
> model/readiness findings; the engineering history after §1 is retained as dated context.

**Written:** 2026-08-02, at the start of an unattended stretch.

---

## 1 · Only you can finish these submission artifacts

**Deadline:** finish and submit before 12:00 PM IST; the portal closes automatically.

| # | Blocker | What to do |
|---|---|---|
| **A1** | **Hosted demo and 2–3 minute video.** | Show the real curve, required filters and ClickStack dashboards live; a screenshot-only demonstration is rejected by the official README. |
| **A2** | **Official team folder and PR.** | Package source, README, architecture, pitch PDF, demo/video links, ClickStack deployment and OTel wiring, redacted `.env.example`, destination service/tables and dashboard captures; open `[Submission] Team Name`. |

Everything else in this file is engineering. These artifacts require a published URL or human-owned
submission action; no local test can substitute for them.

## 2 · What I could NOT do while you slept, and why

**Resume a stalled agent session.** `sc` denies cross-worktree commands to this session
(`cross_worktree_denied` — it is pinned to the main checkout). If an agent paused on rate limits,
it stayed paused until you pressed ▶. **Their work is never lost** — I preserve and push uncommitted
work on every poll, and eight branches were saved this way before the unattended stretch began.

**Write to the graded database.** Deliberately. `sonyliv` was corrupted twice in two days, and the
second time was recoverable only because `ev_raw` was intact. Every guard stays on.

**Merge anything to `main` without a Codex verdict.** See §3.

## 3 · The promotion gate — status, and why nothing has landed

`main` holds the deck, the artifacts and the promotion baseline. It is **~190 commits behind `dev`**.

Three promotion attempts, **three rejections, all on real defects** found by Codex after passing my
own review:

| wave | defect | state |
|---|---|---|
| **W1** foundations | `GRADED_DB` was caller-overridable → **both** graded-database guards defeatable | fixed (`618b9c6`), **Codex re-validating** |
| **W2** model correctness | ADR 0009 claimed `any()` was gone; its own `sql/40_deltas.sql` still executed it — an **incomplete cherry-pick** | fixed, **Codex re-validating** |
| **W3** publication | could not *run* check 3: `main`'s `apply-sql.sh` has no `--database` parser | **parked** until W1+W2 land |

**None of those would have surfaced from a wholesale `dev` → `main` merge.** That is the whole case
for the second level you asked for.

**W3's refusal also produced the sharpest finding of the night:** on `main` as it stands, there is
**no route that installs `sql/12_publish.sql` anywhere but the graded database**, because
`apply-sql.sh` sources `.env` after the caller's environment. That is a property of `main` today, and
it is the exact shape of the incident that already happened.

### If the gate has not finished by the time you read this

[`docs/PROMOTION_FALLBACK.md`](docs/PROMOTION_FALLBACK.md) states the fallback and why it is
defensible: promote wave-by-wave until a cutoff **you** set, then merge `dev` → `main` as one commit
whose message says exactly which features were individually gated and which were not. `dev` is not
unreviewed — it has been through three Codex audits, two promotion validations, a property suite, 11
golden cohorts and an executable edge-case matrix. But three of three gated waves found something, so
it is unlikely the rest are clean, and the commit message must say so.

**Do not weaken the six checks to make waves pass faster.** A rejection costs a re-run; a bad
promotion costs the submission.

## 4 · What landed on `dev` while you slept

Everything is merged with evidence. The findings worth knowing:

**The `150s` criticism you raised was right, and measuring it inverted the answer.** `GAP_S` sits on
a **flat** region (±20% moves the peak 10 viewers, 0.34%); `TAIL_S` is on a **straight ramp** at
+2.41 viewers per tail-second — **7.2× more elastic**. The constant you worried about is the safe one.
And making `GAP_S` dynamic would be *worse*: 55.75% of adjacent event pairs share a truncated second,
so "p99 of inter-arrival" is 45 s or 155 s depending on whether those count.

**The still-open session, characterised** — the live edge **under-reports** (61 of 65 wrong cells are
under-counts, largest over-count +2) and is **exact beyond 240 s**, matching the model's own revision
horizon `GAP_S + TAIL_S = 210 s`. Under-counting is the safe direction for a foreground-only metric.

**The cricketer spike** — correctness holds at 1k/10k/100k arrivals in one minute; served peak is
exactly `2,917 + N`. A spike lands in `sum(starts)`, not row count.

**Two unseen-day killers, both measured:**
- One corrupted `event_timestamp` costs the **entire** 905,558-row file, and `content_dim` inserts
  first and survives — leaving a half-populated database. Quarantine cannot help: it operates *after*
  typing. Y1 is building the all-`String` landing table for this.
- A seconds-vs-milliseconds session relocates the answer to **1970 under a green gate**. The
  source-contract gate's probe 3 catches it *before* the model is built — verified.

**Two model defects, sized honestly:** Q34 (user > session concurrency) is real and **off-by-one on
28 cells**, headline untouched. Q35 (zero-length segments erase 182 point-activity runs) moves the
peak **2,917 → 2,927** — that one **changes a number we would submit**, so it is a proposal, not a
change. Y2 is on both.

## 4b · What changed after this file was first written

**The promotion method changed, and the reason is evidence.** Four attempts were rejected for the
same root cause: cherry-picking commits onto `main` reconstructs a state by hand and misses
follow-ups. Then a decisive test — `sql/50_hour_agg.sql` implements ADRs **0003, 0006, 0014, 0016 and
0022**, i.e. waves 2, 3 and 6 at once. **No ADR-based partition of that file exists**, so the
original wave plan was unachievable rather than merely slow.

Waves are now partitioned by **file**, and a wave is built by **copying `dev`'s version of its files**
rather than replaying commits. `dev` is the state where those claims are true and gate-green, so a
copy cannot produce the defect that rejected the four attempts.

**The first candidate built this way is `promo/w12-fileset`** — ten tooling files, `make ci` green,
all four target paths and all three guards verified live, check 4a passed. It is with Codex now. If
its verdict is PROMOTE, merge it to `main`; that is the first thing to check.

**Two more defects were found and fixed overnight**, both by Codex audits:
- `load.sh --replace` could TRUNCATE the graded database with no acknowledgement — and `ev_raw` is
  the one thing a rebuild cannot recover. Both incidents this week were survivable *because* it was
  intact. Now guarded.
- The **one-command** unseen path never invoked the source-contract gate. The protection existed in
  the runbook and not on the path anybody actually runs. Now wired in.

**One correction to a number I published:** Q34 is **82** violating cells with 63 at zero sessions,
not the 28 and 0 I reported. My query inner-joined `cc_user_minute` to `cc_minute_delta` on minute,
but the delta table carries only change points — a dense table compared to a sparse one. Severity
verdict unchanged; the sizing was wrong.

## 4c · Blocked on you, beyond the two in §1

**Y2 is halted at a permission prompt** (`sc-tunneled-cryostat-2015`) that I cannot approve —
cross-worktree commands are denied to this session. Its work is preserved and pushed. It is the agent
fixing Q34/Q35/U3-F1, **including Q35, which changes a number we would submit** (peak 2,917 → 2,927).
Worth unblocking early.

## 4d · Final overnight state

**`dev` verified end to end at the close:** gate PASSED (17,028 minutes, 0 mismatched), `make ci`
green, tiers coherent — `ev_raw` 905,558 · intervals 30,323 · deltas 28,073 · hour peak 2,917 ·
user peak 2,844.

**`promo/core` is the candidate to land.** 64 files byte-identical to `dev`, passing checks 1, 2, 3,
4b and 6 on the first attempt — the first of six candidates to do that. It needs only Codex check 5,
and its validator is one of the three stalled sessions.

**All four Codex audit findings are closed**, three of them by direct work rather than by an agent:
Q36 (`--replace` guard), Q38 (real timings, 1.7–2.1× the runbook's), Q39a (the inverted anchor,
withdrawn not softened), Q39b (three stale business statements). **Q37 alone remains open** — the
contract gate and the runner disagree about a valid file — and its partial work is safe on
`fix/contract-gate-runner-agreement`.

**One bug I introduced and an agent caught.** My source-contract block in `tools/unseen-run.sh`
referenced `$TARGET`, which that script never sets; under `set -u` the one-command unseen path would
have **died at the gate I added to protect it**. Fixed. It was found because an agent re-read the
file instead of trusting my commit message.

## 4e · Y2 — preserved, deliberately NOT merged

`chore/y2-the-three-defects` carries ~795 insertions touching
`sql/30_build_intervals.sql`, `sql/45_user_concurrency.sql` and `sql/90_reconcile.sql` — the
shared-spec trio — plus `evidence/adr-0031/` and three helper scripts.

**I left it on its branch on purpose.** It is mid-work (halted at a permission prompt), unverified,
and it changes the model. One of its three fixes is **Q35, which moves the peak 2,917 → 2,927** — a
number we would submit. Merging unverified model changes that alter a submitted answer is the one
thing this whole review structure exists to prevent, and doing it while you were asleep would have
been worse than leaving it.

**Unblock it, let it finish, then review Q35 as a decision rather than a merge.** ADR 0031 is
supposed to present both readings — is a viewer who generated exactly one event watching for one
cadence, or not at all? We currently answer "not at all" **by accident rather than by decision**, and
that is the choice to make deliberately.

## 4f · A new tool worth knowing about

`tools/promotion-deps.sh <branch>` derives a promotion's file set from **references** rather than
directory names, and reports what the candidate omits. Two of six rejections were that exact failure,
found by hand both times. Run it before every future promotion — it found the last one in one
command: the source-contract gate was shipping without the SQL it executes.

## 5 · Where to look when you wake

```bash
git checkout dev && git pull
cat docs/PROMOTION.md          # the gate, the ledger, all three refusals
cat docs/PROMOTION_FALLBACK.md # the cutoff decision, which is yours
cat docs/WORKTREE_QUEUE.md     # Q30-Q35, everything open
TARGET=cloud tools/reconcile.sh   # confirm the gate is still green
```

Then check the agent worktrees — several will have finished, and any that show `[idle]` with commits
are **done**, not stalled. `tools/close-worktree.sh <name>` refuses to close one whose work is not
merged or pushed, so it is safe to run on anything.
