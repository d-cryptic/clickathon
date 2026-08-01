# evidence/query-performance.md — what the 13 benchmark shapes read, and why

> **Summary:** All 13 benchmark shapes ranked by **bytes read** (not latency), from
> `evidence/benchmark/results/runs.tsv` + `EXPLAIN indexes=1` + `system.query_log`. Worst: b08
> (833.6 KB — 55% of it a bounded `content_dim` catalog scan), b11 (565.2 KB), b06 (319.5 KB — the
> shape that degrades worst at scale: one hour costs the whole day partition, measured 3.9M rows at
> 100×). Hour-tier shapes read **one 8,192-row granule regardless of range length**. Also here: the
> discovery that `proj_by_session` is already live on the graded DB (→ ADR 0021), a validated
> minute-projection proposal for `cc_minute_delta`, and the reconcile gate green after everything.

Audit date 2026-08-01 · bench tag from `evidence/benchmark/results/meta.env` · Cloud 26.2.1.525 ·
all graded-database access **read-only**; every experiment ran in scratch DB `sonyliv_q25`
(created, measured, dropped this session). Query ids in `runs.tsv` make every number auditable in
`system.query_log`.

## 1 · The ranking, by bytes read (median of 3, caches off — identical across runs)

| # | shape | rows read | bytes read | what is actually read |
|---|---|---:|---:|---|
| 1 | b08 day peak/avg, video-type filter | 60,086 | 833,647 | whole delta day partition (26,622) **+ full `content_dim` scan (33,464)** for the `IN` subquery |
| 2 | b11 ragged range (10:17→11:31) | 34,815 | 565,225 | 1 hour-tier granule (8,193) + whole delta day partition (26,622) for the two partial hours |
| 3 | b05 hour grain, one day | 8,192 | 344,064 | 1 granule of `cc_hour_agg`; widest column set (peak, peak_minute, integral per row) |
| 4 | b06 minute curve, one hour, no filter | 26,622 | 319,464 | **the whole delta day partition, for one hour** — see §3 |
| 5 | b12 day grain, all days | 8,192 | 278,528 | 1 hour-tier granule, day rollup columns |
| 5 | b13 top-10 content in peak hour | 8,192 | 278,528 | 1 hour-tier granule + `dictGet` enrichment (dictionary, not a scan) |
| 7 | b01 day peak/avg, total | 8,193 | 245,761 | 1 hour-tier granule; minute branch prunes to **0 parts** (hour-aligned range) |
| 7 | b02 day, platform cube level | 8,193 | 245,761 | same granule, cube level `(platform,*,-1)` |
| 7 | b03 day, country cube level | 8,193 | 245,761 | same |
| 7 | b04 day, content cube level | 8,193 | 245,761 | same |
| 7 | b10 **13-day** range, total | 8,193 | 245,761 | **identical read to b01** — range 13× longer, bytes unchanged |
| 12 | b07 minute curve, platform filter | 16,384 | 212,992 | 2 delta granules — platform is the sort-key **prefix**, granule pruning works |
| 12 | b09 day, partial platform (`IN` 2 values) | 16,384 | 212,992 | 2 delta granules — same prefix pruning, the documented hour-tier fallback |

Two structural reads of this table:

- **The hour tier is O(1 granule) in range length.** b01 (1 day) and b10 (13 days) read the same
  8,193 rows: under `cc_hour_agg`'s key `(platform, country, content_id, hour)` the headline cube
  level `('*','*',-1)` is one contiguous run found by **binary search** (1/4 granules in every
  explain file). Per `schema-pk-cardinality-order` and ADR 0002/0003/0012, this is the design
  working as intended: range cost is O(stored hour rows), floor-limited to one granule.
- **Bytes track columns × granules, not rows.** b05 reads 344 KB from the same 8,192 rows that
  cost b12 278 KB — it reads more columns per row. The floor for any MergeTree read is one granule
  (8,192 rows) times the columns touched; below that, "optimising" is noise. Per
  `agent-query-safety`'s spirit, the numbers here come from `X-ClickHouse-Summary` and
  `system.query_log`, never from timing alone.

## 2 · b08, the worst by bytes — and why it is right anyway

`system.query_log` for the recorded run (`30fca501-…`): `tables =
['sonyliv.cc_minute_delta','sonyliv.content_dim']`, 60,086 rows. The split is exact:
26,622 delta rows + 33,464 catalog rows.

- The **catalog scan is 55% of the rows** and is the price of resolving `video_type` →
  `content_id` set once per query. The alternative the query header documents — per-row
  `dictGet(...) = {p_video_type}` in the WHERE — fails on 26.2 (Code 43) *and* would be slower:
  one bounded 33,464-row scan beats 26,622 dictionary probes. Per
  `query-join-consider-alternatives`, the dictionary stays for enrichment (b13) and the `IN`
  subquery serves filtering. Bounded by catalog size, not by audience — it does not scale with load.
- The **delta scan reads the whole day partition** because `content_id` is 3rd in the sort key and
  the 193-element set defeats generic exclusion at this granule count (explain: PrimaryKey 4/4
  granules). Per `schema-pk-filter-on-orderby`, a non-prefix filter cannot use the index; per
  `query-index-skipping-indices`, a bloom-filter skip index on `content_id` is the textbook remedy
  **but** its own "when NOT to use" applies: matching values are scattered across all 4 granules of
  a 26,622-row partition — there is nothing to skip at this scale. Re-evaluate only if a 100×
  partition shows content values clustering.

**Verdict: right as designed.** The read is bounded (catalog + one day partition), and both halves
were chosen against measured alternatives.

## 3 · b06 — small today, the worst shape at scale

One hour of dashboard curve reads 26,622 of the table's 28,073 rows — **94.8% of
`cc_minute_delta`, for 60 output points** — because partition `20260726` holds nearly all rows and
`minute` is 4th in the sort key `(platform, country, content_id, minute, …)`: an unfiltered time
slice has no usable prefix (`schema-pk-filter-on-orderby`), so the **day partition is the only
pruning unit** (`schema-partition-query-tradeoffs`). ADR 0002 chose dimension-first deliberately —
filtered dashboards (b07: 2 granules) are the common case — but the total-level curve pays O(day)
per hour.

At 1× that is 319 KB and invisible. At 100× it is measured, not extrapolated:
`evidence/scale.txt` Q7 (same shape) reads **3,946,351 rows / 15.19 MiB — 96.6% of the 100× delta
table — for one hour**. Q3/Q4 (hour tier) stay at 8,192 rows / 176 KB at every scale. b06 is the
benchmark's only shape whose read grows with the *audience* rather than with its own window.

**Validated proposal (not applied — `cc_minute_delta` belongs to `sql/10_intervals.sql`):** a
minute-leading projection on the delta table. Measured in scratch `sonyliv_q25` on the clone of the
graded data, running the committed `b06` SQL with its committed params:

| | rows | bytes | answer |
|---|---:|---:|---|
| base table (= graded today) | 26,622 | 319,464 | committed answer |
| with `PROJECTION proj_by_minute (SELECT * ORDER BY minute)` | 16,384 | 196,608 | **byte-identical** |

1.6× at 1× — granule-floor-limited (hour 10's rows span 2 granules) — but the read becomes
O(window granules) instead of O(day partition), which is what matters at 100×. Verified further:

- Requires `deduplicate_merge_projection_mode = 'rebuild'` — Cloud's `SharedAggregatingMergeTree`
  refuses `ADD PROJECTION` outright under the default `throw` (Code 344, verified 26.2.1.525).
- Survives an `OPTIMIZE … FINAL` merge: projection rebuilt (28,073 rows), b06 answer still
  byte-identical, reads unchanged.
- No regression elsewhere: b07 (platform-prefix shape) reads its usual 16,384 / 212,992 with the
  projection present — the optimizer keeps the base key where the prefix wins.
- Cost: 134.65 KiB beside a ~99 KiB table (≈ +136% of a very small thing).
- b11's partial hours would **not** benefit *on this file*: hours 10–11 genuinely hold ~all delta
  rows (88% of events), so there is nothing to prune — measured, both predicate forms read 26,622.

**Recommendation: adopt only if the unfiltered minute curve becomes a hot path at 100×.** On this
file every minute-tier read is under 1 MB; the change is 3 statements and re-validated by the b06
answer diff above whenever the owner wants it.

## 4 · b11 — the decomposition works; the leftover cost is data concentration

b11 = 8,193 hour-tier rows + 26,622 delta rows. The ADR 0003 decomposition caps it at ≤2
partial-hour minute scans for *any* range length — the design already bounds the worst case. Two
details from the explain file worth keeping honest:

- The view's partial-hour predicate `toStartOfHour(minute) IN <set>` is opaque to **partition**
  analysis (`Partition: Condition: true`) — the MinMax index rescues part pruning (1/7). When the
  set is empty (hour-aligned ranges, b01/b10) it prunes to **0/7 parts**: the fallback costs
  nothing when unused.
- The 26,622-row read is not a pruning failure: those two partial hours *contain* ~95% of the
  table's rows. No index fixes reading data that matches.

**Verdict: right as designed;** re-check the `toStartOfHour IN` form against partition pruning if
the unseen day spreads load across many days (then MinMax granularity, not partitions, does the work).

## 5 · The `ev_raw` projection — deployed since 10:12, docs said shelved (→ ADR 0021)

Not a benchmark shape (no benchmark query reads `ev_raw` — verified via `system.query_log`), but
this audit's task 3. Full story and decision in
[ADR 0021](../docs/adr/0021-keep-proj-by-session-regularise-its-ddl.md); headline numbers, scratch
DB, settled parts, finalizer's actual `IN (subquery)` scope:

| shape | no projection | with projection | factor |
|---|---|---|---|
| windowed derive (`tools/publish.sh`) | 106,497 / 7.20 MB | 8,193 / 614 KB | **13.0×** |
| session-only lookup | 299,351 / 20.1 MB | 38,946 / 2.61 MB | 7.7× |
| dashboard hour+platform | 303,104 / 22.0 MB | 303,104 / 22.0 MB | unchanged |

Storage +3.38 MiB (+92%). Decision: **keep** (it is already on the graded table;
`system.mutations` shows ADD+MATERIALIZE at 2026-08-01 10:12, before this session).
`sql/60_projection.sql` is now database-agnostic (ADR 0010 pattern) — the old hard-coded file
would have **mutated the graded table under any `--database` flag**; the fixed file was validated
against `sonyliv_q25` while `sonyliv`'s mutation log stayed still.

Proposed one-line doc corrections for their owners (files held by other agents today):
- `WALKTHROUGH.md` §5: "measured and not shipped" → "measured, deployed 2026-08-01 10:12, kept by ADR 0021".
- ADR 0013 "ships neither": add a pointer to ADR 0021 for the deployed state.

## 6 · Gate

After all measurements and the scratch DB drop: `TARGET=cloud tools/reconcile.sh` → **PASSED,
17,028 minutes compared, 0 mismatched, peak 2,917**. Writes to `sonyliv` this session: **zero**
(its `ev_raw` mutation log still shows only the two 10:12 entries; benchmark answers b06/b07
reproduced byte-identical from the clone).

## Verdicts at a glance

| shapes | verdict |
|---|---|
| b01–b05, b10, b12, b13 (hour tier) | **Already right.** O(1 granule) in range length; floor-limited. Do not touch. |
| b07, b09 (prefix-filtered minute tier) | **Already right.** Sort-key prefix prunes to 2 granules. |
| b08 | **Right as designed.** 55% of it is a bounded catalog scan chosen against a measured worse alternative. |
| b11 | **Right as designed.** Decomposition caps the fallback; leftover cost is data concentration, not pruning failure. |
| b06 | **Right today, the one to watch at 100×.** Validated minute-projection proposal above; owner's call. |
| `ev_raw` (finalizer path) | **Projection kept** — ADR 0021; DDL defect fixed in `sql/60_projection.sql`. |
