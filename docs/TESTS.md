# TESTS — the catalog

> **Summary:** What is tested, what each test actually proves, and the anti-patterns that make a green
> suite meaningless here. The load-bearing test is `/reconcile` — everything else is secondary. Tests
> that assert against the serving layer alone prove nothing; correctness tests must recompute from
> `ev_raw`.

## The suite

| Test | Proves | Run by |
|---|---|---|
| `/verify-env` | the stack is actually configured — schema present, users real, constraints active | after any env change |
| `/reconcile` | the serving layer equals the truth recomputed from raw | after **every** model change |
| `/bench` | benchmark latency and, more importantly, **bytes read** | before demo / unseen run |
| open-session probe | the model absorbs sessions with no `VideoSessionEnd` | before the unseen run |
| late-arrival probe | a heartbeat arriving after its minute was aggregated updates the served value | before the unseen run |

## How to write a correctness test here

Recompute from `ev_raw`. A test that compares `cc_minute_delta` against a view over
`cc_minute_delta` proves only that arithmetic is deterministic.

## Anti-patterns — these make the suite lie

- **Asserting on the serving layer only.** The whole risk is that the model is wrong; comparing it to
  itself cannot find that.
- **Testing only on the provided file.** It has **zero open sessions** — the path most likely to break
  on the unseen day is completely unexercised. Truncate the file to create one.
- **Testing only `country`.** It has a single value; a filtering bug is invisible. Always also test
  `platform` (10 values).
- **Trusting a green health check.** A failed init script leaves the container `Up` and
  `/api/health` returning `200` with a half-built schema.
- **`set -e` in a script that pipes to `tee`.** It does not fire — the script reports success while
  writing empty files. Use `set -euo pipefail`.
