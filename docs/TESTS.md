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
| hour-clip probe | an interval spanning ≥3 hours reads correctly **at a minute inside the middle hour** — the case that fails if clipping is wrong | after any change to delta emission |
| stitch-boundary probe | a query spanning the watermark neither double-counts nor drops the boundary minute | after any change to `W` or the serving view |
| straggler probe | a heartbeat dated inside an already-sealed window moves the served value to match a brute-force recomputation from `ev_raw` | before the unseen run |
| tail-sensitivity sweep | peak/avg across `HEARTBEAT_GAP_S` ∈ {120,150,180} × `TAIL_GRACE_S` ∈ {0,60,150} — proves robustness, or names the point we knowingly chose | before submission |

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
- **Asserting a corrected value merely *changed*.** After a straggler lands, the served number must
  equal a brute-force recomputation from `ev_raw` — "it moved" passes even when it moved to the wrong
  value.
- **Trusting approximate aggregates in a correctness test.** `uniq` carries 1–2% error. A reconcile
  that compares two `uniq` results agrees with itself while both are wrong. Use `uniqExact` everywhere
  a number is served or asserted.
