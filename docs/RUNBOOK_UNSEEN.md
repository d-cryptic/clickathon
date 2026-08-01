# RUNBOOK — the unseen day

> **Summary:** One command runs the whole path on a dataset we have never seen —
> `UNSEEN_DB=<fresh_name> tools/unseen-run.sh <raw.csv> <content.csv>` — into an isolated scratch
> database, ending on the self-targeting correctness gate (`sql/90_reconcile.sql`, run verbatim; the
> script asserts its SUMMARY row against the day's own minute spine). **Measured end to end: 47 s for
> 30,097 events · 54 s for 6,887 · 58 s for 849,888** — fixed-cost dominated, budget ~3 min even for a
> 5× day. Peak minutes resolve to the **earliest tied minute (ADR 0014) at every tier**. Ten unseen-day
> assumptions (A1–A10) and the ten findings of the synthetic-day rehearsal (R1–R10) are the body of
> this document. Evidence: [`evidence/unseen-rehearsal.txt`](../evidence/unseen-rehearsal.txt) (holdout
> + full-size replay) and [`evidence/unseen/rehearsal.txt`](../evidence/unseen/rehearsal.txt) (synthetic).

**Rehearsed three times, 2026-08-01:**

| run | input | events | peak | gate | wall |
|---|---|---:|---:|---|---:|
| holdout | byte-exact slice, 2026-07-25 | 30,097 | 13 | green | 47 s |
| full-size replay | 2026-07-26 day | 849,888 | 2,887 | green | 58 s |
| **synthetic** | **manufactured day 2026-08-15** — designed to hit every [trap](DATA_DICTIONARY.md#traps), answer known analytically | 6,887 | **30 @ 20:00 (64-minute tie)** | green, **and matches the designed truth on all 1,081 minutes** | 54 s |

The synthetic day matters most: it is the only run where the *right answer* was known independently
of both the model and the gate, and it caught seven defects a green gate could not
(R1–R7 below) — including a **wrong submitted peak minute under a tie**, with the gate green.

---

## 0. Before the day starts

| Check | Command | Expected |
|---|---|---|
| Cloud reachable | `tools/ch -c "SELECT version()"` | a version string, ~1 s |
| `ch` container up | `docker ps --filter name=^ch$` | one running container |
| `.env` complete | `grep -c '^CH_' .env` | ≥ 6 |
| Pick a **fresh** scratch DB | `tools/ch -c "SELECT name FROM system.databases"` | **choose a name NOT in the list** |

**Do not reuse `sonyliv_unseen` blindly (R8).** The script DROPS its target database first, and with
several agents working concurrently, the default name may hold someone else's live state — it did on
2026-08-01 (`sonyliv_unseen`, `sonyliv_trunc` and `sonyliv_verify` all existed at preflight). Pick a
fresh `UNSEEN_DB=` name; it costs nothing.

**The content CSV must already be on disk.** `tools/fetch_data.sh` is sha256-pinned to the *July*
files and cannot fetch a new day (A9). If content is not re-delivered, pass the literal `none` and
accept `(unknown)` titles knowingly.

Multi-statement SQL goes over the native protocol **through the `ch` docker container**
(`tools/apply-sql.sh` does the same). If docker is not running, nothing in this runbook works.

---

## 1. The run

```bash
UNSEEN_DB=sonyliv_unseen_<slug> tools/unseen-run.sh /path/to/unseen-raw.csv /path/to/content.csv
```

That is the whole thing. It drops and recreates the scratch database, applies the schema, loads via
`tools/load.sh`, derives intervals, deltas, the user tier, the hour cube, the content and window
views, runs the gate, and asserts the gate's coverage. It exits **1** on any mismatch and writes
`evidence/unseen-rehearsal.txt` (override with `UNSEEN_OUT=`, subdirectories fine).

Targeting `sonyliv` requires `UNSEEN_ALLOW_PROD=1` — it is the graded state and the script truncates
tables. There is no reason to do this before the model answer is final and reviewed.

### What each phase does, verifies, and costs

Wall clock, measured. Columns: synthetic 6,887 · holdout 30,097 · replay 849,888 events.

| # | Phase | Verifies | 6.9k | 30k | 850k |
|---|---|---|---:|---:|---:|
| 0 | preflight | CSV header matches the loader's **positional** column list; DB empty; SQL fingerprint recorded | <1 s | <1 s | <1 s |
| 1 | schema `00`, `10` | tables + `mv_stateless` exist **before** the load — it is the only populator of `cc_minute_stateless`, there is no backfill | 5 s | 5 s | 5 s |
| 2 | load `tools/load.sh` | `count(ev_raw)` **equals** the CSV data-row count; `cc_minute_stateless` non-empty | 12 s | 9 s | 18 s |
| 3 | intervals `30` | `session_intervals` non-empty; prints intervals / open / active hours | 2 s | 4 s | 3 s |
| 4 | user tier `45` | `cc_user_minute` non-empty | 3 s | 3 s | 4 s |
| 5 | deltas `40` | TRUNCATE-then-insert (a second insert **doubles** every number); non-empty | 3 s | 2 s | 3 s |
| 6 | views `20`, hour `50`, content `80`, windows `85` | hour tier reports a peak **at the earliest tied minute (ADR 0014)** | 15 s | 15 s | 14 s |
| 7 | the answer | session / user / stateless peaks; peak minute = **earliest tied (ADR 0014)**; tie count on the **dense spine** | 5 s | 2 s | 2 s |
| 8 | the gate | `sql/90_reconcile.sql` **verbatim**; then asserts SUMMARY: verdict PASS **and** `minutes_compared` = the day's spine | 4 s | 4 s | 5 s |
| | **TOTAL** | | **54 s** | **47 s** | **58 s** |

**Extrapolation.** 123× the events cost 1.07× the wall clock — the path is dominated by DDL, view
creation and HTTP round trips, not volume. Only phase 2 tracks size (~0.085 s per MB of CSV over the
venue link). A 1 GB unseen day: load ~90 s, everything else unchanged, **total ~2.5 min**. If the
link is slower than the rehearsal's, phase 2 is the only number that moves.

### Expected output, tail of a good run

```
sql/90_reconcile.sql, verbatim (SUMMARY + up to 20 mismatches + 5 samples):
     0  SUMMARY  minutes_compared=1080  mismatched=0  max_abs_diff=0  peak=30  PASS
     2  sample   2026-08-15 06:00:00  1  1  0  PASS
     ...
     asserted: minutes_compared=1080 equals the day's spine (06:00:00 .. 23:59:00)
...
VERDICT — GATE PASSED on <db>. peak 30 @ 2026-08-15 20:00:00 (earliest tied minute).
```

The SUMMARY row is the gate of record: `mismatched` must be 0 and `minutes_compared` must equal the
number of minutes between the first and last event — the script computes that from the loaded data
and **dies if they differ**, so a gate that tests less than it claims can no longer pass silently.
If phase 7 reports more than one tied minute, the submitted minute is the **earliest** and you should
say so next to the answer (ADR 0014; ties are normal — 5 of 7 delivered days have one).

---

## 2. When a step fails

| Symptom | Cause | Do this |
|---|---|---|
| `raw CSV header does not match what tools/load.sh inserts` | new/renamed/reordered column | **Do not "fix" it by editing the header.** `tools/load.sh` maps columns by POSITION through `input(...)`. Update `RAW_COLS` and the `INSERT … SELECT` column list in `tools/load.sh`, then re-run. |
| `ev_raw holds N rows, the CSV has M data rows` | partial load, or an append onto a previous load | The script drops the DB first, so this means the load itself failed midway. Re-run; if it repeats, load in two halves and compare. |
| `cc_minute_stateless is EMPTY after the load` | schema applied *after* the data | Drop the database and re-run. Ordering is not optional. |
| `session_intervals is empty` | the derivation matched nothing — usually a timestamp-unit problem | `SELECT min(event_timestamp), max(event_timestamp) FROM <db>.ev_raw`. If you see 1970 or 56000, the source is **not** epoch millis and `tools/load.sh` divides by 1000 unconditionally. |
| `rendered file … still names another database (in code, comments are ignored)` | a `sql/` file genuinely qualifies a database name in executable text | Extend `render()` in `tools/unseen-run.sh`; do not disable the guard. Comments cannot trip it since R2. |
| `run_file got no file — render() failed` | render/assert died inside command substitution | The real error is printed immediately above (R3). Fix that; this line only stops the cascade. |
| `the gate printed no SUMMARY row` | `sql/90_reconcile.sql` regressed to a form whose silence is unreadable | Treat as FAILURE. The gate must derive targets from `ev_raw` and emit SUMMARY (fixed in `81c0161`). |
| `the gate compared N minutes but the day spans M` | gate spine and loaded data disagree — templating or a partial load | Do **not** submit. Compare `min/max(event_timestamp)` in `ev_raw` against the gate's `bounds`. |
| `GATE FAILED` with non-zero `mismatched` | a real disagreement between the serving layer and `ev_raw` | Re-run the gate body and `WHERE diff != 0` for the offending minutes. Do **not** submit. |
| `REFUSING TO LOAD: <db> already holds data` | loading on top of a previous load — the loader stopped before writing anything (A4) | Decide, do not retry blindly. Redo: `tools/load.sh --replace …`. Second file on purpose: `--append`. |
| `database '<db>' does not exist on TARGET=local` | `.env` has no `CH_DATABASE_LOCAL` (A5) | Add `CH_DATABASE_LOCAL=default` to `.env`, or pass `--database default`. Do **not** create a local `sonyliv`. |
| `--database X contradicts CH_DATABASE=Y` | flag and exported variable disagree (A5) | One of the two is not what you think. Make them agree or unset `CH_DATABASE` for that command. |
| `the 'ch' docker container is not running` | docker down | `docker compose up -d`, wait for healthy, re-run. |

---

## 3. What the synthetic rehearsal found (R1–R10) — all fixed or flagged, 2026-08-01

A manufactured day (`tools/unseen-gen.sh`: 176 sessions, every trap designed in, per-minute answer
computed by a **third independent implementation**) was run through the runbook exactly as written.
Full transcript with the failure and both re-runs: [`evidence/unseen/rehearsal.txt`](../evidence/unseen/rehearsal.txt).

- **R1 · FIXED — phase 6 died on a clean day, machine-dependent.** `render()` used `sed "s/\b…/"`;
  BSD/macOS sed has no `\b`, so the database-templating **never fired on this laptop**. Now perl.
- **R2 · FIXED — comments could kill the run.** ADR 0010's comments in `sql/80_content.sql` *quote*
  the old `sonyliv.dict_content` defect; `assert_isolated` grepped prose as code and died even where
  the code was clean. The guard now strips `--` comments first — executable text still trips it.
- **R3 · FIXED — errors inside `$(render …)` cascaded.** A `die` in a command substitution exits only
  the subshell; the parent ran on with an empty filename. `run_file` now validates its argument.
- **R4 · FIXED — `UNSEEN_OUT` into a subdirectory crashed** before anything ran (`mkdir -p evidence`
  was hard-coded). Now `mkdir -p "$(dirname OUT)"`.
- **R5 · FIXED — the submitted peak minute was WRONG under a tie, with the gate green.** Bare
  `argMax` answered 21:10 where the designed earliest tied minute was 20:00. This closes A8: phases
  6 and 7 now apply ADR 0014 (earliest tied minute) and both answered 20:00 on the re-run. **A gate
  on values cannot see a wrong tie-break** — only a designed-truth run can.
- **R6 · FIXED — the tie count itself lied**: "minutes tied: 2" against a designed 64. The
  change-point view only carries minutes where the level *changes*; the count now runs on the dense
  spine.
- **R7 · FIXED — phase 8 had drifted from the rewritten gate.** G1 "five targeted minutes" only
  swapped the cosmetic *sample* rows (and only via a regex accident), and G2's perl rewrite silently
  no-opped, printing ~1,080 sample rows instead of its documented one-line summary. The gate now runs
  **once, verbatim**, and the script asserts `SUMMARY.minutes_compared` against the day's spine.
- **R8 · FLAGGED — the default scratch DB may be someone else's live state.** Preflight found
  `sonyliv_unseen` still populated from the earlier rehearsal; a literal run would have dropped it.
  §0 now says: pick a fresh name.
- **R9 · MEASURED, OPEN — the A10 sentinel collision is real.** A genuine `content_id = -1` session
  (true hour peak 1) is served as **peak 2** from `cc_hour_agg` — indistinguishably merged with the
  all-content sentinel rows. Total-tier numbers are unaffected; any *per-content* query for id −1 is
  wrong. If the unseen day contains `-1` in the event stream, say so and exclude it from cube claims.
  The fix (a dedicated `is_total` flag or a different sentinel) is a schema change owned elsewhere.
- **R10 · CORRECTED (docs) — missing content ids serve `(unknown)`, not `''`.** The dictionary
  carries a default, so blank-content behaviour is visible in output rather than silent (updates A9's
  wording). `-987654399`, `-1` and `21000099` all returned `(unknown)` titles; joins did not error.

**What the synthetic day PROVED, beyond the defects:** open sessions at the file boundary carry
`is_open = 1` and their tail credits into the next day correctly (12/12 designed); never-seen
dimension values (`VISION_PRO`, `nepal`, `mai`) flow to the serving tier unharmed (trap 4); negative
`content_id` loads and aggregates (trap 5); same-second pause/resume loses zero time and splits no
interval (ADR 0009, 8/8); `speed-pause` decoys open no pause window (A3, 2.10 h exactly as designed);
out-of-order and after-`VideoSessionEnd` events land in the right intervals; and the serving layer
matched the designed truth on **all 1,081 minutes including eight designed-idle ones and the
past-midnight tail minute**.

---

## 4. Older assumptions (A1–A10), status after three rehearsals

- **A1 · FIXED `81c0161`** — the gate's targets were 2026-07-26 literals; on any other day it
  compared nothing and passed. Now derives targets from `ev_raw`; SUMMARY row asserted by the script.
- **A2 · FIXED `81c0161`** — idle minutes were never compared (a fabricated 500-viewer idle minute
  passed). Dense spine now compares them as 0 = 0; the synthetic day checked 8 designed-idle minutes.
- **A3 · OPEN, mitigated** — model and gate share vocabulary (`pause`/`resume`) and tunables
  (`GAP_S`, `TAIL_S`), so a renamed event on the new day silently no-ops in both. Before trusting any
  number, run the three probes below. The synthetic day proves the *decoy* direction (`speed-pause`
  is not treated as pause); the *renamed-pause* direction remains unprovable by any self-referential
  gate — only vocabulary inspection catches it:

  ```sql
  SELECT event, count() FROM ev_raw GROUP BY event ORDER BY 2 DESC;      -- 'pause'/'resume' present?
  SELECT event_type, count() FROM ev_raw GROUP BY event_type;            -- 'VideoSessionEnd' present?
  SELECT quantileExact(0.99)(d) FROM (                                    -- is GAP_S=150 still ~3x p99?
    SELECT dateDiff('second', lagInFrame(event_timestamp) OVER
      (PARTITION BY video_session_id ORDER BY event_timestamp), event_timestamp) AS d
    FROM ev_raw) WHERE d > 0;
  ```

  If p99 has moved, `GAP_S` must change in `sql/30_build_intervals.sql` **and** `sql/90_reconcile.sql`
  in the same edit.
- **A4 · FIXED (loader)** — re-loading doubles the day on Cloud (SharedMergeTree; insert dedup does
  not fire — measured 60,194 from 30,097). `tools/load.sh` refuses when tables hold rows; `--replace`
  / `--append` decide on purpose. The schema comment claiming idempotency is still wrong.
- **A5 · PARTLY FIXED** — `load.sh` and `apply-sql.sh` resolve `--database` > environment > `.env`
  and hard-error on contradictions. `build-model.sh`, `reconcile.sh`, `truncation-test.sh`, `tools/ch`
  still let `.env` win.
- **A6 · FIXED (ADR 0010)** — `sql/80_content.sql` names no database; views pin to their own
  database's dictionary at CREATE time. The `render()` guard stays as the standing check (and, since
  R2, reads code only). Related: **never run bare `tools/apply-sql.sh`/`make sql-cloud` on the day**
  — with no arguments it applies *every* `sql/*.sql`, including `60_projection.sql` (ALTERs
  `sonyliv.ev_raw`) and `70_truncation_test.sql`.
- **A7 · OPEN, inherent** — a day-file cut at midnight is self-consistent, so the gate cannot see
  boundary loss (measured: 2 boundary minutes differ vs a full-context build on 2026-07-25). The
  first and last minutes of a standalone day-file are approximations; say so.
- **A8 · CLOSED by R5/R6** — ADR 0014 (earliest tied minute) is now applied by the script's own
  display queries at both tiers, verified against a designed 64-minute tie.
- **A9 · UPDATED by R10** — content metadata must be re-delivered (fetch script is sha-pinned to July
  files); missing ids serve `(unknown)` titles rather than erroring. Pass `none` only knowingly.
- **A10 · smaller things, still real** — timestamp units (loader divides by 1000 unconditionally;
  check `min/max(event_timestamp)` after load); `content_id = -1` collides with the cube sentinel
  (**now measured — see R9**); AggregatingMergeTree `count()` is not a build identity (compare
  `sum(delta)/sum(starts)/sum(ends)`); `50_hour_agg` re-runs supersede only under `FINAL`; the
  HyperDX chart range is a human step and defaults to the July window in the docs.

---

## 5. What needs a human, mid-run

1. **Pick the scratch database name** (R8) — fresh, agreed in the team channel, so no concurrent
   worktree is dropped.
2. **Run the A3 vocabulary probes** and decide whether `pause`/`resume`/`VideoSessionEnd` still mean
   what they meant. If the p99 gap moved, re-tune `GAP_S` in **two files at once**.
3. **The unclosed-pause rule** remains undecided (23% of pauses never resume; conservative vs
   permissive is +99.3 h / 5.09% on the delivered file, +131 on the PEAK). Unknowable from the data;
   the shipped default is conservative. See `doubts/`.
4. **Set the HyperDX chart range** to the unseen day (A10). No API call in the repo does this.
5. **If `content_id = -1` appears in the event stream** (R9): state that per-content numbers for that
   id are unreliable and exclude it from cube claims.
6. **Check dimension drift before trusting any FILTERED number** (TODOS · doubts/04). The pipeline
   does not apply `sql/15_normalise.sql` — do it by hand in the scratch DB, then read the summary:
   `TARGET=cloud tools/apply-sql.sh --database <db> sql/15_normalise.sql` and
   `SELECT * FROM <db>.v_dimension_drift_summary`. On the delivered file, raw-vs-normalised is worth
   **+23.6% on the Hindi peak** with the total peak unchanged — a new day's casing/sentinel mix can
   move any filtered answer by that class of margin.
7. **Team Captain submits.** Only they can.

---

## 6. Reproducing the evidence

```bash
# the synthetic rehearsal — generator, run, designed-truth verification
tools/unseen-gen.sh                      # writes data/unseen-synthetic-{raw,content}.csv + designed truth
UNSEEN_DB=sonyliv_unseen_q18 UNSEEN_OUT=evidence/unseen/run-output.txt \
  tools/unseen-run.sh data/unseen-synthetic-raw.csv data/unseen-synthetic-content.csv
UNSEEN_DB=sonyliv_unseen_q18 tools/unseen-verify.sh   # designed truth vs served, + trap probes
tools/ch -c "DROP DATABASE sonyliv_unseen_q18"        # leave nothing behind

# the holdout used in rehearsal #1 — a byte-exact slice of the delivered file
awk -F',' 'NR==1{print; next} {t=$6+0; if (t>=1784937600000 && t<1785024000000) print}' \
  data/ch-hackathon-raw-data.csv > unseen-day-2026-07-25.csv    # 30,097 rows

# the full-size replay
UNSEEN_DB=sonyliv_unseen_scale tools/unseen-run.sh <2026-07-26.csv> data/ch-hackathon-content-data.csv
tools/ch -c "DROP DATABASE sonyliv_unseen_scale"
```

The synthetic day's designed truth lives in `evidence/unseen/designed-truth.tsv` (epoch minutes, so
no server timezone can shift it); the manifest of what was designed and why is
`evidence/unseen/designed-manifest.txt`.
