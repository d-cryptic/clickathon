# TESTS — the catalog

> **Summary:** What is tested, what each test actually proves, and the anti-patterns that make a green
> suite meaningless here. The load-bearing test is `/reconcile` — everything else is secondary. Tests
> that assert against the serving layer alone prove nothing; correctness tests must recompute from
> `ev_raw`.

## The suite

| Test | Proves | Run by |
|---|---|---|
| `/verify-env` | the stack is actually configured — schema present, users real, constraints active | after any env change |
| `tools/validate-source-contract.sh` | input can be interpreted by the current state machine: lifecycle identity is unambiguous, timestamps/dimensions are valid, and all content references resolve | before every materialization or unseen-file run |
| materialization empty-source guard | a wrong or empty target cannot erase a prior derived model under `--replace` | before Cloud rebuilds and unseen-file runs |
| `/reconcile` | the serving layer equals the truth recomputed from raw | after **every** model change |
| `tools/verify-model.sh` | state stops cut intervals and sampled delta reconstruction matches direct interval overlap | after every batch materialization |
| `tools/query-concurrency.sh` | minute-grid serving query produces exact peak/average, including zero minutes | before benchmark / API changes |
| query-range input guard | invalid or inverted UTC minute ranges fail before building a minute grid | after CLI changes |
| half-open minute-boundary regression | an interval ending exactly at `HH:MM:00` does not count that minute, while a fractional close does | after any delta-emission change |
| `/bench` | benchmark latency and, more importantly, **bytes read** | before demo / unseen run |
| `tools/truncation-test.sh [cutoff]` | the model absorbs sessions with no `VideoSessionEnd`; a temporary staged exact tail equals raw-derived active concurrency at the cut and no interval extends beyond its 60-second grace | before the unseen run |
| late-arrival probe | a marker arriving after its minute was aggregated changes the served value to an independent raw re-derivation | before the unseen run |
| finalizer publication probe | staged correction rows do not affect a query before `published`; the same rows do after publication | after finalizer changes |
| finalizer resume probe | re-running a prepared run produces the same target state, never a second additive correction | after finalizer changes |
| session-incarnation probe | one reused `video_session_id` with two lifecycle ids cannot carry foreground/pause state across the boundary | before accepting a live source change |
| tied-transition regression | same-timestamp pause/resume/heartbeat receives stop → start → activity precedence, independent of input row order | after state-order changes |
| `tools/synthetic-edge-test.sh` | adversarial state transitions, dimension handoff, duplicate payload, error continuation, and exact-minute stop behavior | after state-machine changes |
| correction time-travel probe | a published correction changes `--as-of-run N` but not an earlier run; invalid run identifiers fail input validation | after serving-query changes |
| hour-clip probe | an interval spanning ≥3 hours reads correctly **at a minute inside the middle hour** — the case that fails if clipping is wrong | after any change to delta emission |
| stitch-boundary probe | a query spanning the watermark neither double-counts nor drops the boundary minute | after any change to `W` or the serving view |
| exact-tail fallback probe | a snapshot is selected only when it belongs to the selected finalizer sequence; a newer correction disables stale tail data | after finalizer or tail changes |
| exact-tail upper-bound probe | a snapshot ending at `T` cannot replace the ledger after `T`; absent tail rows after its range must not become false zeroes | after tail-serving changes |
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
