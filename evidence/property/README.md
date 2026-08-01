# evidence/property/ — random sessions, checked against first principles

> **Summary:** A reference interpreter (`tools/reference_interpreter.py` — plain Python over sets of
> seconds, derived from the SPEC with every convention citing its dossier) and a property harness
> (`tools/property-test.sh`) ran **400 seeded random cases × 2 modes** through the REAL pipeline
> (`sql/30` → `sql/40` → `sql/45` in local scratch db `prop_t6`), checking all seven Codex 003 §13.2
> properties with ddmin shrinking. **The serving algebra is clean** — expansion ≡ running sums, batch
> split/merge/reorder invariance, idempotence, correction algebra `old+(−old+new)=new`, non-negativity:
> **0 failures in 400 cases.** Two REAL disagreements found, both shrunk to ≤4-event counterexamples and
> both measured on the delivered file: (1) the derivation **drops point activity** — 182 lone-event runs
> in the real file count zero; keeping them moves the graded peak 2,917 → 2,927 (+0.34%) and +5.0 h —
> and (2) **user concurrency can exceed session concurrency** at a filtered grain — 82 real-file cells,
> 63 of which serve ≥1 user with **0 sessions**. Neither is fixed here: the SQL belongs to other owners.

**Measured:** 2026-08-02 · local ClickHouse 26.7 (`default.ev_raw`, 905,558 rows) · scratch db
`prop_t6` (graded `sonyliv` never touched; the harness speaks only to `CH_LOCAL_URL` and refuses any
database not named `prop_*`).

---

## Why this exists

The reconcile gate recomputes truth from `ev_raw` with different code but the **same definitions** as
the model, so a wrong shared convention goes green on both sides (`evidence/adversarial/` measured 21
of those), and it checks **one file**, so it says nothing about session shapes that file lacks.
Property testing attacks both limits: generate **random** sessions, compute the answer from first
principles in an implementation with no shared code and no shared blind spots, and compare — then let
the pipeline's own algebra (batching, idempotence, corrections) testify about shapes no fixture
anticipated.

## The harness

- `tools/reference_interpreter.py` — the counting spec in ~120 lines of plain Python: sets of whole
  seconds, pauses subtracted, contiguous ranges read back off. Conventions C1–C9 each cite their
  dossier (`doubts/01/02/05/06/07/08/09/11`, ADR 0007/0008/0009). A `model_compat` flag reproduces
  the shipped SQL's zero-length-segment drop — the one place this file knowingly disagrees with
  `sql/30_build_intervals.sql` (see finding 1).
- `tools/property-test.sh [N] [SEED0]` — seeded generator (every anomaly attested in the real file:
  out-of-order rows, same-second pause/resume, unclosed and trailing pauses, backgrounding gaps, lone
  beats, open sessions, post-end events, duplicate rows, mid-session dimension drift, minute-aligned
  timestamps, negative content ids), the real DDL applied to `prop_t6`, the real `sql/30`/`40`/`45`
  run per case, seven properties, and ddmin shrinking (sessions first, then events). Failures land
  here with their seed; `tools/property-test.sh --case <seed>` replays one case exactly.

**Calibration.** Fed the delivered file, the interpreter in `model_compat` mode reproduces the graded
headline **exactly**: 30,323 intervals · 1,978.1 h · peak 2,917 @ 2026-07-26 10:56 — the same numbers
`sql/30_build_intervals.sql` (arraySplit), `sql/90_reconcile.sql` (window functions) and
`evidence/adversarial/README.md` report. Three implementations, three idioms, one answer.

## Results — 400 cases, seeds `20260802-0 … 20260802-399`, both modes

| property (Codex 003 §13.2) | cases | spec mode | compat mode |
|---|---|---|---|
| P1 optimized state machine ≡ reference interpreter | 400 | **319 fail** → finding 1 | 0 fail |
| P2 interval expansion ≡ delta running sums, every minute+grain | 400 | 0 fail | 0 fail |
| P3 batch invariance (split / merge / reorder) | 40 | 0 fail | 0 fail |
| P4 idempotence (block dedup + duplicate rows inert) | 40 | 0 fail | 0 fail |
| P5 correction algebra `old + (−old + new) = new`, every cell | 40 | 0 fail | 0 fail |
| P6 user tier ≡ its mirror, and user ≤ session per grain | 400 | **7 fail** → finding 2 | **7 fail** → finding 2 |
| P7 no negative concurrency, any minute, any grain | 400 | 0 fail | 0 fail |

P2 compares at the FULL 7-dimension grain (hour-clipped running sums reconstructed per ADR 0003), not
just totals. P3 loads the same multiset as one block, split blocks, and shuffled+reversed blocks. P4
checks both `non_replicated_deduplication_window` block replay and physically duplicated rows. P5 runs
`sql/40_deltas.sql` on four interval sets (full-old, changed-old, changed-new, full-new) and asserts
the identity per (minute, dims) cell — the exact per-session purity `tools/publish.sh` relies on
(ADR 0006/0013). The clean sweep on P2–P5+P7 is the headline for the serving layer: the delta algebra
holds on 400 random days that the delivered file never showed it.

---

## Finding 1 — the derivation drops POINT ACTIVITY (P1, spec mode, 319/400 cases)

`sql/30_build_intervals.sql` filters zero-length segments (`arrayFilter(x -> x.2 > x.1, …)`) **before**
granting tail credit. The comment justifies the drop only for the same-second pause-tie split (where
both readings agree anyway); as a side effect it also erases activity whose extent is a single instant:

- **a lone-event run** — one event, >150 s of silence on both sides. The viewer demonstrably acted at
  that instant; the stated tail convention (one cadence after the last event of a run — the
  interval-math skill states it with no lone-beat exception) reads it as `[t, t+60]`. The model emits
  **nothing** — not even the instant's own minute.
- **a boundary instant** — a resume landing exactly on the run's last second, or a pause opening a
  run: the instant itself is dropped.

The shrunk counterexample is **one event** ([failure-P1-20260802-0-spec.md](failure-P1-20260802-0-spec.md)):
a session whose only row is a single beat produces zero intervals. Across the 400 generated cases the
model dropped 983 point intervals (683 lone-event runs, 204 run-end boundary instants, 95 mid-run
instants) — frequencies are generator-shaped, so the number that matters is the **real file**:

- **182 lone-event runs** exist among the 14,954 runs of the delivered file (175 sessions);
- keeping point activity moves the headline **peak 2,917 → 2,927 (+10, +0.34%)**, hours
  **1,978.1 → 1,983.1 (+5.0 h, +0.25%)**, and changes **80 of 3,732 minutes** (max per-minute delta 16);
- the reconcile gate carries the **identical filter** (`sql/90_reconcile.sql`), so it is green on both
  readings by construction — this is precisely the shared-convention class the gate cannot see.

One benign sub-case for completeness: a pause with its resume in the **next** second (`p, p+1`) splits
the model's interval into two abutting ones while the spec reading keeps one; no whole second and no
minute changes either way (seed `20260802-309`). It is an attribution boundary, not a counting change.

**Not fixed here** — `sql/30_build_intervals.sql` and `sql/90_reconcile.sql` have owners. This is a
convention fork of the same species as doubts/07/09 (worth +10 peak / +5 h if we have it backwards),
and it deserves a dossier: the mentor question is *"does a viewer whose player emitted exactly one
event in an isolated moment count at that minute?"* Both readings are defensible; the model currently
answers no, the spec sentence in the skill answers yes.

## Finding 2 — user concurrency EXCEEDS session concurrency at a filtered grain (P6, both modes, 7/400 cases)

The session tier and the user tier attribute dimensions **differently**, and the difference is visible
in served answers:

- `sql/40_deltas.sql` merges a session's minute-touching intervals and the merged run keeps the
  **first interval's** dimension tuple (ADR 0012);
- `sql/45_user_concurrency.sql` expands **per interval** at the (platform, country, content_id) grain
  (ADR 0016).

A session whose dimension attribution changes across a short pause (interval 1 dominant `ANDROID_PHONE`,
interval 2 dominant `IPHONE`, both touching the same minutes) is served as an `ANDROID_PHONE` session —
while its user is served under **both** platforms. Filter a dashboard on the second platform and it
shows **1 concurrent user and 0 concurrent sessions**: a logically impossible pair, and a direct
violation of Codex 003 §13.2's "user counts never exceed session counts at the same filter grain".

Shrunk to **4 events** ([failure-P6-20260802-69-spec.md](failure-P6-20260802-69-spec.md)); identical in
compat mode, so it is independent of finding 1. The P6 *mirror* check passed everywhere — each tier does
exactly what its file says; the two stated conventions simply contradict each other. Real-file exposure,
computed by applying each tier's convention (each proven equal to its SQL by this suite) to the
30,323-interval baseline (`adv_q19.si_baseline`):

- **25 sessions** carry more than one (platform, country, content_id) attribution across intervals;
- **82 (minute, grain) cells** serve user > session; **63 of them serve users ≥ 1 with sessions = 0**
  (e.g. 2026-07-25 20:23 UTC, ANDROID_TAB / india / content 2078158496: 1 user, 0 sessions).

**Not fixed here** — the fix is a design decision between ADR 0012 and ADR 0016 (make the user tier
expand per merged run, or make the session tier split runs at attribution changes — the latter
re-imports the double-count `/reconcile` once caught), owned by `sql/40`/`sql/45`.

---

## Relationship to tools/unseen-gen.sh

`unseen-gen.sh` already contains a third implementation of the counting spec (plain Python sets), but
it is a **generator with analytically known answers for hand-built blocks** — it computes designed
truth for sessions it constructed, and cannot read an arbitrary event stream. The reference
interpreter **replaces it for this purpose rather than extending it**: same spirit (sets, no
ClickHouse), but a general interpreter over any input, which is what a random-input harness needs.
Its compat mode implements `unseen-gen.sh`'s spec sentence (runs split at >150 s on whole seconds,
pause `[p, resume ≥ p)` subtracted, conservative to run end when unclosed, +60 s tail on run-end
segments, inclusive minute cover) — and reproduces the graded headline exactly, which `unseen-gen`'s
block-local arithmetic could not have shown.

## What this does NOT cover

- **13.3 failure injection** (finalizer kill/restart, dual finalizers) — out of scope here;
  `tools/publish-test.sh` territory. P5 proves the correction *algebra*, not the publisher's
  crash-safety.
- The **permissive** unclosed-pause variant exists as a flag in the interpreter but only the shipped
  conservative rule was campaign-tested.
- `cc_hour_agg` / windows / content views — downstream of the tiers tested; not exercised.
- Failure **rates** in the table are generator-shaped (the generator plants lone beats in ~16% of
  sessions); only the real-file exposures above are portable numbers.

## Reproduce

```bash
tools/property-test.sh 400 20260802                  # spec mode, ~15 min
PROP_COMPAT=1 tools/property-test.sh 400 20260802    # compat mode
tools/property-test.sh --case 20260802-69            # replay one case
PROP_DB=prop_t6  # scratch db; must start with prop_; drop it when done
```

Run logs: [run-spec-20260802-N400.txt](run-spec-20260802-N400.txt) ·
[run-compat-20260802-N400.txt](run-compat-20260802-N400.txt). Every failure in them carries its seed.
