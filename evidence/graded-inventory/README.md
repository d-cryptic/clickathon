# evidence/graded-inventory/ — raw captures behind docs/GRADED_INVENTORY.md

> **Summary:** Read-only captures from the graded Cloud database `sonyliv`, taken 2026-08-02 for the
> Q31 inventory. Numbered files are direct system-table dumps (tables, MV/view DDL, mutations,
> projections, dictionaries, UDFs, part times, DDL/insert history from query_log, attribution,
> reconcile-at-inventory). `ddl_diff.py` is the drift-check prototype: render repo SQL into a local
> scratch db, normalize DDL both sides, diff — it produced `17-ddl-diff.txt` and found every drift
> in the inventory. Query-log captures are non-durable evidence (replica-local); mutations and part
> times are the durable spine. See docs/GRADED_INVENTORY.md §4 for the proposed tools/graded-drift.sh.

| File | What |
|---|---|
| `01-tables.txt` | All 58 `sonyliv` objects: engine, keys, rows, size, metadata time |
| `02-mvs-ddl.txt` | CREATE of the 3 materialized views (incl. retired-in-repo `mv_user_minute`) |
| `03-mutations.txt` | Complete `system.mutations` history (11, all repo-issued) — **baseline for drift check #2** |
| `04-projections.txt` / `05-skip-indexes.txt` | `proj_by_session` (3.42 MiB) + 3 skip indexes |
| `06-dictionaries.txt` / `14-dict-ddl.txt` | `dict_content` status + DDL |
| `07-udfs.txt` | 5 SQLUserDefined functions (match `sql/15_normalise.sql`) |
| `08-base-tables-ddl.txt` | Full CREATE of all 11 base tables |
| `09-ddl-history-sonyliv.txt` | query_log DDL, all clickathon databases (scratch dbs incl.) |
| `10-databases.txt` / `19-other-databases.txt` | Databases on the service; scratch leftovers sized |
| `11-ddl-sonyliv-only.txt` | query_log DDL scoped to database `sonyliv` (1,229 rows) |
| `12-part-times.txt` | Active-part modification times (dates the 16:39 rebuild) |
| `13-views-ddl.tsv` | Full CREATE of all 43 views |
| `15/16-*-objects.txt` | Object-name sets: repo render vs Cloud |
| `17-ddl-diff.txt` | Normalized DDL diff output — 37 identical, drift itemized |
| `18-reconcile-at-inventory.txt` | Read-only reconcile vs raw: PASS, 17,028 minutes, 0 mismatch |
| `20-attribution.txt` | Who ran the projection / user-tier / publisher DDL (all `default`, repo tooling) |
| `21-insert-history.txt` | Every insert touching `sonyliv` (215) — proves single `ev_raw` load |
| `ddl_diff.py` | Drift-check prototype (run: apply repo SQL to local scratch `inv_drift`, then `python3 ddl_diff.py`) |
