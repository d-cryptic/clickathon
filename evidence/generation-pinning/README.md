# evidence/generation-pinning — a half-built model, made unservable

> **Summary:** The 2026-08-02 incident reproduced and then defeated. Today's design, given a build
> that dies after the delta insert, serves **peak 5,834 / 56,146 rows** against a true 2,917 /
> 28,073 — bit for bit what the graded database did. The generation-pinned design of
> [ADR 0034](../../docs/adr/0034-generation-pinned-serving-surface.md) serves **2,917 / 28,073**
> through the same failure, twice: once killed after staging, once run to completion with the
> corruption intact so the gates fire. Cost on all 13 benchmark shapes, unmodified: **+0.0% rows
> read, +16.7% bytes read** (that is the `generation` column), **+1.45 ms/query** with the
> generation baked as a literal, **+3.5–5.8 ms/query** through the control-table pointer.
> ADR 0023's reason for rejecting generation gating is reproduced *and* dissolved: it holds only
> while `generation` is payload, not when it leads the sort key. All local, ClickHouse 26.7.1.1315;
> the graded database is never written.

## Files

| File | What it is |
|---|---|
| `00-setup.sh` / `.txt` | Two scratch databases from the same `ev_raw`: **`gp_ctl`** built the way the graded database is built today, **`gp_pin`** converted to the pinned surface and built through `tools/build-generation.sh`. Both end at peak 2,917 / 28,073 rows — the pin is transparent to every existing view. |
| `10-final-vs-where.sh` / `.txt` | **ADR 0023's objection, tested both ways.** `generation` as payload → `SELECT … FINAL WHERE generation = 1` returns **0 rows**, exactly as ADR 0023 predicted. `generation` leading the sort key → the right row, every time. Test 3 is the trap that replaces it: **`FINAL` over a normal view is a silent no-op** (2 rows/30 where the truth is 1 row/20). |
| `20-pointer-cost.sh` / `.txt` | Does `WHERE generation = (SELECT …)` still prune? On 3 generations × 1M rows: literal **1.00 M rows / 11.44 MiB**, pointer **1.00 M / 11.44 MiB**, unpinned **3.00 M / 22.89 MiB**. Plus `DROP PARTITION` of a 1M-row generation: **40 ms**, metadata only. |
| `40-killed-build.sh` / `.txt` | **The proof.** Case A: today's design, build dies at stage 4/6 after a doubled delta insert → serves **5,834**. Case B1: pinned, `KILL_AFTER=stage` → serves **2,917**. Case B2: pinned, run to completion → verify gate reports `served peak 5834 vs true 2917`, generation abandoned, still serves **2,917**. |
| `50-bench-cost.sh` / `.txt` / `.tsv` | The 13 benchmark shapes, unmodified, three ways: today / pinned-with-pointer / pinned-with-literal. Repairs `gp_ctl` first (case A leaves it doubled on purpose — a doubled baseline is not a baseline). |
| `60-commit-window.sh` / `.txt` | How long the commit takes and how long tiers can disagree: one INSERT (median 74.5 ms, **no window at all**) vs four `CREATE OR REPLACE VIEW` (median 79.0 ms, window = the whole span). ADR 0023 measured today's cross-tier window, unpinned, at 3.8–7.3 **s**. |

## The four numbers that matter

| Measurement | Value |
|---|---|
| Served peak after a build dies mid-way, **today** | **5,834** (true 2,917), 56,146 delta rows (true 28,073) |
| Served peak after the same failure, **ADR 0034** | **2,917**, 28,073 rows — unchanged, in both kill modes |
| Reader cost of pinning, 13 benchmark shapes | **+0.0% rows**, **+16.7% bytes**, +1.45 ms/query (literal) / +3.46–5.76 ms/query (pointer) |
| Cost of holding an extra generation | **0 rows read** (partition-pruned); ~2× storage on the derived tiers; retirement is a 40 ms `DROP PARTITION` |

## Reproduce

```bash
evidence/generation-pinning/00-setup.sh          # ~10 s, builds gp_ctl and gp_pin
evidence/generation-pinning/10-final-vs-where.sh # ~5 s
evidence/generation-pinning/20-pointer-cost.sh   # ~15 s
evidence/generation-pinning/40-killed-build.sh   # ~20 s   <- the proof
evidence/generation-pinning/50-bench-cost.sh     # ~90 s   (repairs gp_ctl first)
evidence/generation-pinning/60-commit-window.sh  # ~15 s
# cleanup
for d in gp_ctl gp_pin gp_probe; do tools/ch "DROP DATABASE IF EXISTS $d"; done
```

Run `40` before `50`: the cost run depends on `gp_pin` holding three generations, which is the
pessimistic case and which `40` is what creates.

## What is NOT here

- **Nothing ran on Cloud, and nothing ran against `sonyliv`.** Every script uses the local target
  and `00-setup.sh` refuses to run if any script in this directory names a write against the graded
  database. Converting the graded database means rebuilding its four tiers — the same destructive
  operation the incident came from — and is an operator decision.
- **No racing-poller run across a commit.** `60-commit-window.sh` measures the two commit mechanisms'
  durations; it does not prove by observation that a reader never sees a mixture. For the
  control-table pointer that is a construction argument (four views, one row), not a measurement.
- **`b13` needed a local-only fix.** `sql/80_content.sql` declares
  `SOURCE(CLICKHOUSE(TABLE 'content_dim'))` with no credentials, which connects as `default` with an
  empty password — right on Cloud, and `AUTHENTICATION_FAILED` in a scratch database on this
  container. `50-bench-cost.sh` redefines the dictionary with credentials **identically in both
  databases**, so the comparison is unaffected; only b13's `dictGet` decoration depends on it, never
  a serving path being measured.
