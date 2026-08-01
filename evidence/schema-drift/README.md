# evidence/schema-drift — ADR 0024: header shape detection + the `extra` catch-all

> **Summary:** Proof pack for ADR 0024. `capture.sh` re-runs everything locally in scratch DBs
> (`adr0024cap_*`, dropped on exit): pre-0024 loader fetched from git (`7c74581`) as baseline,
> new loader proven **fingerprint-identical** on the 13-column path; NEW columns announced +
> carried into `extra` (empty maps +0.48%, populated 2-key +3.6% compressed, load time unchanged);
> MISSING columns refuse without `--allow-missing`; reconcile PASSes on a new-column file's model;
> new dim filterable end to end — tier 0.2 s when a function of a key, raw fallback 0.23 s when not.

| file | what |
|---|---|
| `capture.sh` | the whole evidence run, 30 assertions, exits 1 on any FAIL. `bash evidence/schema-drift/capture.sh`; `KEEP=1` keeps the scratch DBs |
| `probes.txt` | its committed transcript — read this |
| `worked-example.sql` | per-minute concurrency filtered on `extra['device_type']`, validated minute-by-minute against a platform-derived ground truth (the probe file computes `device_type` FROM `platform`, so the two filters must agree; SUMMARY row asserts it) |
| `raw-fallback-network.sql` | the no-migration path for a dimension that is a function of NOTHING in the tier key |

Averages in the worked example's per-device rows are over minutes where that device class had any
activity (the series has no idle-minute spine), at minute grain — stated per the one-scope rule.

Probe headers exercised: `device_type` mid-header + `network_type` appended (full 905,558-row
file), `app_version` dropped, `video_session_id` dropped (hard refusal), full reorder, duplicate
header name, `'weird name; DROP TABLE'` (injection-shaped, refused).
