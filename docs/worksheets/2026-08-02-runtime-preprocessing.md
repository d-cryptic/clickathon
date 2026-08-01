# Worksheet — 2026-08-02 · T3 runtime preprocessing (ADR 0025)

**Goal** Hostile input handled at runtime: reject/quarantine/normalise policy, quarantine table with
reason codes, cost measured on the full file, gate provably unchanged.

**Done**
- `sql/15_normalise.sql` §6–8: `norm_scrub` (unicode hygiene inside `norm_case`), `q_reason` /
  `q_flags` classifiers, `ev_quarantine` (ReplacingMergeTree, idempotent sweep), views
  `v_ev_model_input`, `v_quarantine_summary`, `v_preprocess_flags`, `v_preprocess_summary`;
  45 self-test assertions on literals.
- `docs/PREPROCESSING.md` — per-class treatment table. ADR 0025 — the policy and its defence.
- `evidence/preprocessing.txt` — survey (provided file is clean on every class), cruel injection
  (10 quarantined with right reasons, 8 kept and counted), byte-identical rebuild, gate PASS
  17,028/0/2,917, costs (sweep 327 ms / 122.63 MiB).

**Verified in scratch** Cloud DBs `t3_preproc` (baseline), `t3_cruel` (+18 hostile rows),
`t3_clean` (rebuild from clean view), `t3_fresh` (empty-DB apply contract) — all dropped after.
Graded `sonyliv` untouched (reads only).

**Open**
- Wiring `v_ev_model_input` into `30_build_intervals.sql` + `90_reconcile.sql` is proposed in ADR
  0025, not applied — two-file change owned by other lanes, must land together.
- Tolerant load (type_mismatch → quarantine instead of batch failure) — recipe in ADR 0025
  §Consequences, owner T1.
- When T2's `cruel-gen.sh` lands: run its output through `v_preprocess_summary`; unclassified rows
  are new classes for `q_reason`/`q_flags`.

**How to verify** Apply `sql/15_normalise.sql` to any scratch DB with `ev_raw`; read
`v_preprocess_summary`. Full replay: evidence/preprocessing.txt header.
