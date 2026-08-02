# evidence/policy — the answers did not move when the constants moved

> **Summary:** ADR 0032 relocated `GAP_S`, `TAIL_S`, `UNCLOSED_PAUSE_TO_RUN_END` and
> `POINT_ACTIVITY_COUNTS` out of six files and into one declaration (`policy/model.policy`), read by
> SQL through the generated view `v_model_policy`. This file is the proof that it was a **relocation,
> not a retune**: two full local builds from the same 905,558-row `default.ev_raw`, before and after,
> agree on every headline AND on a `cityHash64` content fingerprint of all four derived tiers —
> **peak 2,917, 30,323 intervals, 28,073 deltas, 91,679 user buckets, all five hashes identical**.
> Three negative controls then prove the wiring is live rather than decorative. Nothing here touched
> ClickHouse Cloud; both builds are local scratch databases (`y2_policy_before`, `y2_policy_after`).

Reproduce: `tools/y2-scratch.sh y2_policy_before` on the parent commit, `tools/y2-scratch.sh
y2_policy_after` on this one, then compare with the queries in §1. Measured 2026-08-02, local
ClickHouse 26.7.1.1315, `default.ev_raw` = 905,558 rows.

---

## 1 · Before vs after — every field identical

`build_version` is `now()` and is excluded from every hash; nothing else is.

| measurement | before (`y2_policy_before`) | after (`y2_policy_after`) | |
|---|---:|---:|---|
| `session_intervals FINAL` rows | 30,323 | 30,323 | = |
| counted watch seconds | 7,121,135 | 7,121,135 | = |
| **minute peak** | **2,917** | **2,917** | = |
| peak minute | 2026-07-26 10:56:00 | 2026-07-26 10:56:00 | = |
| `cc_minute_delta` rows | 28,073 | 28,073 | = |
| delta opens / closes | 20,002 / 16,826 | 20,002 / 16,826 | = |
| `cc_user_minute FINAL` buckets | 91,679 | 91,679 | = |
| user peak | 2,844 | 2,844 | = |
| `cc_hour_agg FINAL` rows | 26,254 | 26,254 | = |
| hour-tier peak | 2,917 | 2,917 | = |

Row-level fingerprints — `cityHash64(groupBitXor(cityHash64(<every column>)))`, which is
order-independent and catches a single changed cell anywhere in the tier:

| tier | fingerprint (before = after) |
|---|---:|
| `session_intervals` (12 columns) | `6825181195659358760` |
| `cc_minute_delta` (11 columns) | `4748050672592136415` |
| `cc_hour_agg` (8 columns) | `6856630394262967464` |
| `v_user_concurrency_minute_total` | `2677613543040261597` |
| `v_concurrency_minute_delta_total` | `3428733969683546420` |

The canonical gate agrees on both builds, and its output is byte-identical once the newly added
`policy` column is removed:

```text
before  0  SUMMARY  minutes_compared=17028  mismatched=0  max_abs_diff=0  peak=2917  PASS
after   0  SUMMARY  minutes_compared=17028  mismatched=0  max_abs_diff=0  peak=2917  PASS  policy=v1/e965954b23d4
```

---

## 2 · Negative controls — the declaration is load-bearing, not decorative

An identical answer is only evidence if a *different* declaration would have produced a different
answer. Three controls, all on local scratch:

**C1 — the MODEL reads the view.** Same tree, same input, one substituted `sql/01_policy.sql` with
`gap_s = 180`:

```text
gap_s = 150   30,323 intervals   1,978.1 h   peak 2,917
gap_s = 180   30,214 intervals   1,975.3 h   peak 2,909
```

If `sql/30_build_intervals.sql` had kept a literal, or if the scalar subquery had been folded from
anywhere else, this would not have moved.

**C2 — the GATE reads the view.** Re-running `sql/90_reconcile.sql` against the `gap_s = 180` build,
with the view still at 180: `minutes_compared=17028 mismatched=0 peak=2909 PASS`. The gate re-derives
truth from `ev_raw` with window functions, so it is agreeing on a *recomputed* 2,909, not echoing the
model.

**C3 — the tripwire survives centralisation.** Re-applying the shipped `sql/01_policy.sql` (back to
`gap_s = 150`) over the 180-built model and re-running the gate:

```text
0  SUMMARY  minutes_compared=17028  mismatched=102  max_abs_diff=14  peak=2917  MISMATCH
1  MISMATCH 2026-07-26 10:49:00  2692  2678  -14
1  MISMATCH 2026-07-26 10:50:00  2726  2716  -10
```

This is the property ADR 0028 §item 4 asked for: model and gate now share the **declaration** rather
than each carrying a copy, and a model built under one policy still fails loudly when served under
another. Sharing the constant did not make the gate blind; it made *whose* constant it is explicit.

**C4 — the drift gate catches a hand-edit.** `sql/01_policy.sql` is generated. Editing it directly
(`gap_s` 150 → 180, leaving the baked-in `policy_hash` alone, exactly the tampering that would make an
answer lie about its policy) is rejected before any build:

```text
== policy check   v1  hash e965954b23d4
-- generated SQL is current
   FAIL  sql/01_policy.sql is STALE. Run: tools/policy.sh gen
```

`tools/build-model.sh` runs that check at stage 0/6 and refuses, so a stale rendering can never be
written into a database and silently build tiers under old values.

---

## 3 · What the check asserts

`tools/policy.sh check` (wired into `tools/test-all.sh` as the `policy` suite, and into
`tools/build-model.sh` stage 0/6) is green on this commit:

```text
-- generated SQL is current
   ok    sql/01_policy.sql matches policy/model.policy
-- declared values are internally consistent
   ok    GAP_S > 0 · TAIL_S >= 0 · both flags in {0,1}
   ok    PUBLISH_MINUTE_COVER_S >= TAIL_S + 60
   ok    PUBLISH_HOUR_COVER_S >= TAIL_S + 60
   ok    PUBLISH_INTERVAL_PREFILTER_S >= TAIL_S + 60
   ok    PUBLISH_LOOKBACK_S > PUBLISH_SETTLE_S
   ok    PUBLISH_LEASE_TTL_S > PUBLISH_LEASE_SETTLE_S
   ok    QUEUE_TTL_DAYS >= 1
-- DDL that cannot read the view still agrees with it
   ok    sql/12_publish.sql: 3 queue TTLs at INTERVAL 7 DAY
   ok    sql/12_publish.sql: no bare 604800 — retention derives from queue_ttl_days
-- no consumer carries its own literal
   ok    no `<n> AS GAP_S`-style literals left in sql/
   ok    no GAP_S/TAIL_S literals left in the oracle or the generators
== policy check PASS
```

The three `>= TAIL_S + 60` assertions are the ones that pay for themselves: before ADR 0032 those
covers were the literals `+241`, `+7201` and `INTERVAL 300 SECOND` in `tools/publish.sh`, none of
which named `TAIL_S`. Raising `TAIL_S` above 240 would have under-covered the publisher's touched-minute
window and left buckets stale **with no error at all** (docs/DYNAMIC_PARAMS.md §A2). It now fails a
gate instead.

---

## 4 · Deployment note

`sql/01_policy.sql` is `CREATE OR REPLACE VIEW` only — no data, no `DROP`, no `TRUNCATE` — so applying
it is non-destructive and per-database. The graded database does **not** have it yet; the next graded
build needs

```sh
TARGET=cloud tools/apply-sql.sh --database sonyliv sql/01_policy.sql
```

before `sql/30_build_intervals.sql` or `sql/90_reconcile.sql` will run there. `tools/build-model.sh`
applies it itself at stage 0/6, so an authorised rebuild handles this automatically. Until it is
applied, those two files fail with `Unknown table expression identifier 'v_model_policy'` — loudly,
which is the intended failure mode.
