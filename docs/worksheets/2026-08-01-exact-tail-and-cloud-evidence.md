# Exact tail and Cloud evidence handoff

> **Summary:** The historical state-gated delta ledger, correction finalizer, and bounded exact tail
> have passed isolated ClickHouse validation. The exact tail is publication-fenced to the finalizer
> version, so a new correction disables stale tail data. Cloud evidence is blocked only because `.env`
> still contains the placeholder host; main's local `ch` contains raw data but no derived tables.

## Goal

Provide foreground-only session concurrency that remains correct for late arrivals and open sessions,
with a defensible evidence path for the unseen day.

## Completed

- State-gated heartbeat sessionizer and hour-clipped delta serving layer.
- Versioned correction finalizer, model-version fence, bitemporal `--as-of-run` replay.
- `exact_tail_minute_stage` plus `exact_tail_run_log`, published only after its matching finalizer run.
- A newer finalizer sequence selected zero stale tail runs; a refreshed matching tail re-enabled it.
- `truncation-test.sh '2026-07-26 10:30:00'`: 144 open sessions, 75 raw-derived and served-tail active
  sessions, maximum 59 seconds past the cut, both assertions zero.
- `reconcile.sh`, `verify-model.sh`, `synthetic-edge-test.sh`, shell syntax checks, and diff whitespace
  checks pass on `sc-cooled-fluxon-1fd5-ch-test`.

## External-state facts

- The user-owned main container `ch` has 905,558 raw events. It was read-only during research and its
  derived tables were empty when inspected.
- The configured Cloud host is the template value `your-service.clickhouse.cloud`; `tools/ch -c
  'SELECT version()'` cannot resolve it. Do not claim a Cloud latency result until the service host and
  credentials are supplied and `/verify-env` succeeds.

## Next steps

1. Provision/fill the real Cloud endpoint, then run `TARGET=cloud tools/deploy-schema.sh`,
   `load.sh`, `materialize.sh --replace`, `bootstrap-finalizer.sh --replace`, `finalize.sh`, and
   `refresh-tail.sh`, and `reconcile.sh`. Each of those commands is target-aware; record the status and
   correctness evidence only from that same Cloud target.
2. Add the organisers’ official benchmark queries under `evidence/benchmark/` and run each three times
   with bytes-read and granule evidence. If those queries are unavailable, label any reconstructed shapes
   as non-official.
3. Run the tail sensitivity grid only after real source arrival telemetry exists; the CSV bulk-load time
   is not a lateness distribution.

## Verification commands

```bash
CH_CONTAINER=sc-cooled-fluxon-1fd5-ch-test tools/truncation-test.sh '2026-07-26 10:30:00'
CH_CONTAINER=sc-cooled-fluxon-1fd5-ch-test tools/reconcile.sh
CH_CONTAINER=sc-cooled-fluxon-1fd5-ch-test tools/verify-model.sh
CH_CONTAINER=sc-cooled-fluxon-1fd5-ch-test tools/finalizer-status.sh
```
