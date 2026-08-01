# HANDOFF — read this first when you wake

> **Summary:** `dev` is healthy and carries everything: gate green on the graded database
> (17,028 minutes, 0 mismatched, peak 2,917), `make ci` green, all four tiers coherent. `main` is
> still ~190 commits behind because the feature-by-feature promotion gate has **correctly rejected
> three of three attempts on real defects** — that is the gate working, not stalling. **Two things
> only you can do, both disqualification-level: the repo is still PRIVATE, and no Team Captain is
> named.** Neither is affected by anything below. If you read nothing else, read §1.

**Written:** 2026-08-02, at the start of an unattended stretch.

---

## 1 · Only you can do these, and they decide whether we can submit at all

| # | Blocker | What to do |
|---|---|---|
| **A1** | **The repo is PRIVATE.** Submission requires public. | Flip it — but run the pre-publication checklist in [`SUBMISSION.md`](SUBMISSION.md) first. The real Cloud **hostname** appears in `evidence/load-guard.txt` and in history at commit `6355048`. A hostname grants no access, but decide deliberately: scrub-and-rewrite, or accept and document. |
| **A2** | **No Team Captain is named.** Only the Captain can submit. | Name one in `SUBMISSION.md`. |

Everything else in this file is engineering. These two are not, and no amount of overnight work
substitutes for them.

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
