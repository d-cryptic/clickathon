# RUNBOOK — the unseen day

> **Summary:** One command runs the whole path on a dataset we have never seen —
> `tools/unseen-run.sh <raw.csv> <content.csv>` — into the isolated database `sonyliv_unseen`,
> ending on the correctness gate. **Measured end to end: 47 s for 30,097 events, 58 s for 849,888
> events**; the path is fixed-cost dominated, so budget ~3 min even for a 5x-bigger day. **The
> committed gate `sql/90_reconcile.sql` does NOT work on a new day** — its five target minutes are
> 2026-07-26 literals, so it returns zero rows and `tools/reconcile.sh` reports PASS having compared
> nothing. That, plus nine more unseen-day assumptions (A1-A10) and five human decisions, is the body of
> this document. Evidence for every claim: [`evidence/unseen-rehearsal.txt`](../evidence/unseen-rehearsal.txt).

**Rehearsed:** 2026-08-01, holdout day 2026-07-25 (204 sessions, 30,097 events, peak 13) and a
full-size replay of 2026-07-26 (10,524 sessions, 849,888 events, peak 2,887). Both gates green.

---

## 0. Before the day starts

| Check | Command | Expected |
|---|---|---|
| Cloud reachable | `tools/ch -c "SELECT version()"` | a version string |
| `ch` container up | `docker ps --filter name=^ch$` | one running container |
| `.env` complete | `grep -c '^CH_' .env` | ≥ 6 |
| Scratch DB free | `tools/ch -c "SELECT name FROM system.databases"` | `sonyliv_unseen` will be dropped and recreated |

Multi-statement SQL goes over the native protocol **through the `ch` docker container**
(`tools/apply-sql.sh` does the same). If docker is not running, nothing in this runbook works.

---

## 1. The run

```bash
tools/unseen-run.sh /path/to/unseen-raw.csv data/ch-hackathon-content-data.csv
```

That is the whole thing. It drops and recreates `sonyliv_unseen`, applies the schema, loads via
`tools/load.sh`, derives intervals, deltas, the user tier, the hour cube, the content and window
views, and finishes on the gate. It exits **1** on any mismatch and writes
`evidence/unseen-rehearsal.txt`.

To target a different database: `UNSEEN_DB=… tools/unseen-run.sh …`. Targeting `sonyliv` requires
`UNSEEN_ALLOW_PROD=1` — it is the graded state and the script truncates tables.

### What each phase does, verifies, and costs

Wall clock from the 2026-08-01 rehearsal. Left column = 30,097 events, right = 849,888 events.

| # | Phase | Verifies | 30k | 850k |
|---|---|---|---|---|
| 0 | preflight | CSV header matches the loader's **positional** column list; DB empty; SQL fingerprint recorded | <1 s | <1 s |
| 1 | schema `00`, `10` | tables + `mv_stateless` exist **before** the load — it is the only populator of `cc_minute_stateless` and there is no backfill | 5 s | 5 s |
| 2 | load `tools/load.sh` | `count(ev_raw)` **equals** the CSV data-row count; `cc_minute_stateless` non-empty | 9 s | 18 s |
| 3 | intervals `30` | `session_intervals` non-empty; prints intervals / open / active hours | 4 s | 3 s |
| 4 | user tier `45` | `cc_user_minute` non-empty | 3 s | 4 s |
| 5 | deltas `40` | TRUNCATE-then-insert (a second insert **doubles** every number); non-empty | 2 s | 3 s |
| 6 | views `20`, hour `50`, content `80`, windows `85` | hour tier reports a peak | 15 s | 14 s |
| 7 | the answer | session / user / stateless peaks, and how many minutes **tie** at the peak | 2 s | 2 s |
| 8 | the gate | G0 verbatim, G1 five derived minutes, G2 every minute | 4 s | 5 s |
| | **TOTAL** | | **47 s** | **58 s** |

**Extrapolation.** 28x the events cost 1.23x the wall clock — the path is dominated by DDL, view
creation and HTTP round trips, not volume. Only phase 2 tracks size (~0.085 s per MB of CSV over the
venue link). A 1 GB unseen day: load ~90 s, everything else unchanged, **total ~2.5 min**. If the
link is slower than the rehearsal's, phase 2 is the only number that moves.

### Expected output, tail of a good run

```
G1 — same gate, five minutes DERIVED from the loaded day:
     2026-07-25 00:00:00  1   1   0  PASS
     ...
G2 — same gate over EVERY minute …
     1364   207   0   0   13   PASS
VERDICT — GATE PASSED on sonyliv_unseen. peak 13 @ 2026-07-25 16:59:00.
```

`G2`'s columns are `minutes_compared · of_which_idle · mismatches · max_abs_diff · peak_truth ·
verdict`. **`mismatches` must be 0.** `minutes_compared` must equal the number of minutes between the
first and last event — if it is smaller, the templating failed and the gate is testing less than it
claims.

---

## 2. When a step fails

| Symptom | Cause | Do this |
|---|---|---|
| `raw CSV header does not match what tools/load.sh inserts` | new/renamed/reordered column | **Do not "fix" it by editing the header.** `tools/load.sh:19` maps columns by POSITION through `input(...)`. Update `RAW_COLS` and the `INSERT … SELECT` column list in `tools/load.sh`, then re-run. |
| `ev_raw holds N rows, the CSV has M data rows` | partial load, or an append onto a previous load | The script drops the DB first, so this means the load itself failed midway. Re-run; if it repeats, load in two halves and compare. |
| `cc_minute_stateless is EMPTY after the load` | schema applied *after* the data | Drop the database and re-run. Ordering is not optional. |
| `session_intervals is empty` | the derivation matched nothing — usually a timestamp-unit problem | `SELECT min(event_timestamp), max(event_timestamp) FROM sonyliv_unseen.ev_raw`. If you see 1970 or 56000, the source is **not** epoch millis and `tools/load.sh` divides by 1000 unconditionally. |
| `rendered file … still names another database` | `sql/80_content.sql` hard-codes `sonyliv` | That guard exists because the file really does. Extend `render()` in `tools/unseen-run.sh`; do not disable the guard. |
| `GATE FAILED` with non-zero `mismatches` | a real disagreement between the serving layer and `ev_raw` | Get the offending minutes: re-run G2 without the summary wrapper and `WHERE served != truth`. Do **not** submit. |
| `the 'ch' docker container is not running` | docker down | `docker compose up -d`, wait for healthy, re-run. |
| G0 prints `ZERO ROWS` | expected on any day that is not 2026-07-26 | See assumption **A1** below. Not a failure of this run. |

---

## 3. What the pipeline assumes about the file, that a new day may violate

Ordered by how much damage each does. Every one is measured in
[`evidence/unseen-rehearsal.txt`](../evidence/unseen-rehearsal.txt).

### A1 — the gate's target minutes are 2026-07-26 literals · **breaks silently, reports success**

`sql/90_reconcile.sql:24-30` hard-codes five minutes. On 2026-07-25 the file returns **zero rows**;
`tools/reconcile.sh:86` decides with `grep -q MISMATCH`, finds none, and prints
`reconcile PASSED`. It also degrades *partially*: on the 2026-07-26 day-file it returned **four** rows
instead of five, because the `2026-07-14 15:43:00` target does not exist in a one-day load — and
nothing asserts the row count. **`make reconcile` is worthless on the unseen day until those five
literals are re-targeted.** `tools/unseen-run.sh` works around it by templating the `targets` CTE.

### A2 — the gate never compares a minute in which nobody was watching

`sql/90_reconcile.sql:153-161` ends `FROM truth AS t LEFT JOIN served AS s`, and `truth` is a
`GROUP BY` over a `CROSS JOIN`, so an idle minute produces no row. **207 of 2026-07-25's 1,364
minutes** are such minutes. Injecting one fabricated row made the chart report **500 concurrent
viewers at an idle minute** and the gate still said PASS — both the five-minute form and an
all-minutes form driven off `truth`. Reproduce, in an isolated DB only:

```sql
INSERT INTO sonyliv_unseen.cc_minute_delta (minute,platform,country,content_id,delta,starts,ends)
SELECT toDateTime('2026-07-25 00:44:00'),'ANDROID_PHONE','india',12345,500,500,0;
```

`tools/unseen-run.sh` G2 drives the comparison off the **minute spine** instead, and reports
`MISMATCH · max_abs_diff 500` on the same data.

### A3 — the gate shares the model's vocabulary and tunables, so a spec error is invisible

`event = 'pause'` / `'resume'` appear in **both** `sql/30_build_intervals.sql:99-100` and
`sql/90_reconcile.sql:77-78`; `GAP_S = 150` and `TAIL_S = 60` are likewise duplicated
(`30:70,73` and `90:18,19`) rather than shared. The delivered file has **47 distinct `event`
values**, several pause-like but non-matching (`speed-pause` 380, `speed-resume` 380, `AdPause` 45,
`AdResume` 27). If the unseen day renames or re-cases pause/resume, exclusion becomes a no-op and the
gate keeps passing. Measured on the holdout: **62.56 h → 71.68 h active, a 14.6 % over-count, with a
green gate.**

Before trusting any number on the day:

```sql
SELECT event, count() FROM ev_raw GROUP BY event ORDER BY 2 DESC;      -- 'pause'/'resume' present?
SELECT event_type, count() FROM ev_raw GROUP BY event_type;            -- 'VideoSessionEnd' present?
SELECT quantileExact(0.99)(d) FROM (                                    -- is GAP_S=150 still ~3x p99?
  SELECT dateDiff('second', lagInFrame(event_timestamp) OVER
    (PARTITION BY video_session_id ORDER BY event_timestamp), event_timestamp) AS d
  FROM ev_raw) WHERE d > 0;
```

If p99 has moved, `GAP_S` must be changed in **both** files, in the same edit.

### A4 — re-loading the same CSV doubles the day; the schema comment says it does not

`sql/00_schema.sql:42-44` claims `non_replicated_deduplication_window = 1000` makes "a replayed batch
idempotent — the unseen day may be re-loaded". Measured on Cloud 26.2.1.525: loading the identical
30,097-row CSV twice left `ev_raw` at **60,194 rows** in two byte-identical parts
(`20260725_0_0_0`, `20260725_1_1_0`, both 30,097 rows / 102,795 bytes). That setting is for
non-replicated MergeTree; the Cloud engine is **SharedMergeTree**. `tools/unseen-run.sh` drops the
database first. If you ever re-load by hand, `TRUNCATE TABLE ev_raw` first.

### A5 — `CH_DATABASE` in the environment is silently ignored

Every tool does `[ -f .env ] && set -a && . ./.env && set +a`, so `.env` **overwrites** anything
passed in the environment. `CH_DATABASE=sonyliv_unseen tools/build-model.sh` writes to **`sonyliv`**.
All of `build-model.sh`, `reconcile.sh`, `apply-sql.sh` and `truncation-test.sh` also `cd` to the repo
root first, so they always read the repo's `.env`. **The only way to point them at another database is
to edit `.env`.** `tools/load.sh` is the one exception (it does not `cd`), which is why
`tools/unseen-run.sh` runs it from a sandbox directory holding an overridden `.env`.

### A6 — ~~`sql/80_content.sql` hard-codes the `sonyliv` database~~ FIXED (ADR 0009)

**Was:** `SOURCE(CLICKHOUSE(TABLE 'content_dim' DB 'sonyliv'))` plus six `dictGet('sonyliv.dict_content', …)`
calls, so applied to any other database those views read **production's** dictionary — reproduced in a
scratch database, where the old form returned production titles for scratch data.

**Now:** the file names no database at all, like every other file in `sql/`. ClickHouse resolves the
dictionary name at `CREATE VIEW` time and bakes it in, so each view is permanently pinned to its own
database's dictionary — verified by applying the committed file with `--database sonyliv_scratch80`
and reading it from a session attached to `sonyliv`. See
[ADR 0009](adr/0009-content-views-are-database-agnostic-and-label-their-ambiguity.md).

`tools/unseen-run.sh` still templates the database name out of every file and still refuses to run one
that names another database. **Keep that guard** — it now has nothing to rewrite in `80_content.sql`,
but it is the standing check that the defect does not come back, here or anywhere else.

Related, and worse if you take a shortcut: **`tools/apply-sql.sh` with no arguments applies every
`sql/*.sql`**, which includes `sql/60_projection.sql` (`ALTER TABLE sonyliv.ev_raw`, twice) and
`sql/70_truncation_test.sql` (`CREATE DATABASE sonyliv_trunc`). Never run bare `make sql-cloud` as
part of an unseen-day run.

### A7 — a day-file answers differently from a full-context build, and no gate can see it

The gate recomputes truth from the **same** `ev_raw` it is checking, so an input that was cut at
midnight is self-consistent and invisible. Measured: on 2026-07-25, 7 of 204 sessions have events
outside the day (583 events dropped), and the day-file build differs from the full-context build on
**2 minutes** — `00:00 → 1 vs 0` and `00:40 → 0 vs 1`. On 2026-07-26 the same shape drops 1,140
events across 7 sessions. If the unseen day arrives as a standalone file, its first and last minutes
are approximations, and saying so is better than being caught.

### A8 — "the peak minute" is ambiguous under ties, and the tiers disagree

On 2026-07-25 four minutes tie at 13 (15:51, 16:35, 16:55, 16:59). `v_concurrency_minute_delta_total`
answers **16:59**; `cc_hour_agg` answers **16:35**. Same peak value, two different answers to *when*.
2026-07-26's peak (2,887) is unique, so this never surfaced. Phase 7 now prints the tie count — if it
is > 1, state the tie-breaking rule with the answer.

### A9 — content metadata is assumed to be re-delivered

`content_dim` is empty in a fresh database, and an empty `dict_content` does **not** error:
`dictGet` returns `''` for every title, video_type and category, so the content views serve blanks.
`tools/unseen-run.sh` refuses to start without a content CSV unless you pass the literal `none`.
`tools/fetch_data.sh` is sha256-pinned to the *current* files, so it cannot fetch a new day — the
file must be placed by hand.

### A10 — smaller things that are still real

- **Timestamp units.** `tools/load.sh:48` divides `event_timestamp` and `session_start_epoch` by 1000
  unconditionally. Epoch **seconds** would land in 1970; ISO-8601 strings would fail the `UInt64`
  parse. Check `min/max(event_timestamp)` after loading, always.
- **Cube sentinels.** `cc_hour_agg` uses `content_id = -1` and `platform/country = '*'` to mean "all".
  No collision in the delivered file (min content_id 20,971,538 in `ev_raw`), but `content_dim`
  *does* carry a negative id (−987,654,322), so a negative `content_id` in event data is not
  unthinkable. If one is `-1`, the cube silently merges it into the all-content level.
- **Row counts are not an identity.** `cc_minute_delta` printed 835 rows on one build of the holdout
  and 837 on the next, for identical aggregates (net 71, opens 455, closes 384) — AggregatingMergeTree
  physical rows depend on merge state. `WALKTHROUGH.md` and `tools/build-model.sh` both quote raw
  `count()` as if it identified a build. Compare `sum(delta)/sum(starts)/sum(ends)`, not `count()`.
- **`sql/50_hour_agg.sql` is not truncated before its INSERT.** It is a
  `ReplacingMergeTree(computed_at)` and the views read `FINAL`, so a re-run supersedes rather than
  doubles — but only if you read `FINAL`. Anything reading it without `FINAL` after two builds is
  wrong.
- **Stale ranges in prose.** `tools/clickstack-sources.sh:85-86` and `tools/clickstack-cloud.sh:273`
  tell the operator to set the chart range to `2026-07-14 → 2026-07-26`, and `docs/` repeats it. The
  HyperDX dashboard has **no** stored time range — it is a human step, and on the unseen day it is
  the wrong instruction.
- **`sql/45_user_concurrency.sql:68`** still describes `session_intervals` as
  `ReplacingMergeTree(interval_end)`. It is versioned on `build_version` now. Stale comment, right
  behaviour.

---

## 4. What needs a human, mid-run

1. **Re-target the gate** (A1). Either accept `tools/unseen-run.sh`'s templated G1/G2 as the gate of
   record, or edit the five literals in `sql/90_reconcile.sql` so `make reconcile` means something.
   Someone must decide which artefact is submitted as the correctness evidence.
2. **Re-tune or keep `GAP_S`/`TAIL_S`** (A3). If the measured heartbeat p99 has moved, keeping 150 s
   is a judgement call — and any change must be made in two files at once.
3. **Set the HyperDX chart range** to the unseen day (A10). No API call in the repo does this.
4. **The unclosed-pause rule** remains undecided (23 % of pauses never resume; conservative vs
   permissive is +99.3 h / 5.09 % on the delivered file). It is unknowable from the data and it
   changes every number.
5. **Team Captain submits.** Only they can.

---

## 5. Reproducing the evidence

```bash
# the rehearsal itself
tools/unseen-run.sh <holdout.csv> data/ch-hackathon-content-data.csv

# the holdout used on 2026-08-01 — a byte-exact slice of the delivered file
awk -F',' 'NR==1{print; next} {t=$6+0; if (t>=1784937600000 && t<1785024000000) print}' \
  data/ch-hackathon-raw-data.csv > unseen-day-2026-07-25.csv    # 30,097 rows

# the full-size replay
UNSEEN_DB=sonyliv_unseen_scale tools/unseen-run.sh <2026-07-26.csv> data/ch-hackathon-content-data.csv
tools/ch -c "DROP DATABASE sonyliv_unseen_scale"
```

The probes behind sections A2, A3, A7 and A8 are transcribed with their SQL in
[`evidence/unseen-rehearsal.txt`](../evidence/unseen-rehearsal.txt). They mutate only
`sonyliv_unseen` and restore it.
