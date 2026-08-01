# evidence/query-modes — point-in-time vs interval, measured

> **Summary:** The measurements behind [`docs/QUERY_MODES.md`](../../docs/QUERY_MODES.md). 25 committed
> query shapes covering both modes × minute/hour/day × unfiltered/one-dim/multi-dim, plus 4 traps and
> 2 ambiguity probes. Costs in `ranking.txt` (ranked by bytes read, caches off, median of 3);
> agreement in `correctness.txt` (C1–C8, exit 0 only if every gate passes). One new defect: **F1**,
> the documented densify recipe invents 10 phantom viewer-minutes across an hour boundary — confined
> to ad-hoc queries, does not reach the serving layer (C8). Everything here is **read-only**.

## What is here

| path | what |
|---|---|
| `ranking.txt` | all 25 shapes ranked by **bytes read**, with reading notes |
| `correctness.txt` | C1–C8: point vs interval agreement, tier agreement, idle-minute semantics |
| `queries/*.sql` + `.params` | the committed shapes — each header says what it proves |
| `results/` | per shape: `.answer.txt` (run 1), `.explain.txt` (`EXPLAIN indexes=1`), `runs.tsv`, `meta.env` |
| `capture.sh` | regenerates `results/` — 1 explain + 3 timed runs per shape |
| `correctness.sh` | regenerates `correctness.txt`; **exit status is the gate** |

## Naming

`pm`/`ph`/`pd` = point at minute/hour/day · `im`/`ih`/`id` = interval at minute-range/hour-series/day-range ·
`tr` = trap (wrong on purpose) · `amb` = ambiguity probe (the answer is the point, not the cost).

## Where these numbers come from

Scratch database **`sonyliv_u3`** on the graded Cloud service: `ev_raw` and `content_dim` copied from
`sonyliv`, then the model rebuilt at dev HEAD (`10 → 30 → 45 → 40 → 50 → 20 → 15 → 85`). Gate-green —
**3,732 minutes, peak 2,917**, hour tier = minute tier.

**Why not measure on the graded database:** it currently serves three tier vintages for 2026-07-26
(`cc_hour_agg` 2,917 / `cc_minute_delta` 2,950 / `session_intervals` 2,681 —
`evidence/query-robustness/README.md` F1), so point and interval queries disagree there for reasons
unrelated to query modes. Cross-tier agreement is only measurable on a single-generation build.

**Writes to `sonyliv` this session: zero**, verified in `system.query_log`. Every write-kind query from
this session ran between 19:44:32 and 19:45:56 UTC and every one names `sonyliv_u3` as its target; all
372 `qmode`-tagged queries are `Select`/`Explain` against `sonyliv_u3`.

**The graded database was mutated by OTHER worktrees while this ran** — a `build-model.sh`-shaped
rebuild at 19:30–19:32 and a `TRUNCATE sonyliv.session_intervals` at 21:23:18, neither from this
session (our first query was 19:44:32). That is a second, independent reason these measurements are
taken on a private scratch build: the graded database was not a stable measurement surface during this
window. `sonyliv.ev_raw` itself was untouched throughout (newest active part 10:12:15), so the copy
taken at 19:44:58 is the same raw input the graded model is built from.

## Methodology

Identical to [`evidence/query-performance.md`](../query-performance.md): caches off
(`use_query_cache=0`, `use_query_condition_cache=0`), rows/bytes from `X-ClickHouse-Summary` and never
from timing, ranked on **bytes read** because latency flatters a warm cache. Every run carries
`log_comment='qmode:<shape>:run<N>:<tag>'` and its query id is in `results/runs.tsv`, so each number is
auditable in `system.query_log`.

All 25 shapes returned a byte-identical answer and an identical read size across 3/3 runs. `tr04`
needed an explicit `ORDER BY` to get there — a bare `UNION ALL` returned its two branches in either
order (same rows, same bytes, different answer file). An evidence file whose committed answer changes
between runs is not evidence.

## Reproducing

```bash
evidence/query-modes/capture.sh        # ~4 min
evidence/query-modes/correctness.sh    # exit 0 only if every gate passes
```

Both default to `QM_DATABASE=sonyliv_u3` and are read-only. To rebuild the scratch DB from scratch, see
the stage list above; **never** run `tools/build-model.sh` against `TARGET=cloud` with the default
database — that is the graded one.

## The headline findings

1. **Both modes work at every grain and filter** — 18/18 matrix cells, verdict per cell in the doc.
2. **Point mode is not cheaper than interval mode.** `pm01` (1 minute), `im05` (26 min) and `im01`
   (74 min) are byte-identical at 597,993. Cost is set by ragged edges, not range length.
3. **Ragged vs aligned is the real cost driver** — 2.15× over the same two hours; a 13-day aligned
   range reads exactly as much as a 2-hour aligned one.
4. **"Concurrency at hour H" is ambiguous by 51×** (2,917 peak / 1,091.03 avg / 57 at H:00) → resolved
   in [ADR 0027](../../docs/adr/0027-concurrency-at-a-coarse-grain-is-a-pair-not-a-number.md).
5. **F1** — the `WITH FILL` densify recipe carries a level across an hour boundary into an hour that
   opened empty. 10 phantom minutes; the fix is one `UNION ALL` anchor, verified over 6,108 minutes.
