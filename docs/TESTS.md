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
| **truncation / absorption test** | the model absorbs mid-stream truncation and a late arrival **incrementally**, converging on the from-scratch answer. Covers the open-session and late-arrival probes below in one run | `tools/truncation-test.sh` — after any change to `session_intervals`, its engine, or the delta emission |
| open-session probe | the model absorbs sessions with no `VideoSessionEnd` | folded into the truncation test (52.6% of sessions are open at the cut) |
| late-arrival probe | a heartbeat arriving after its minute was aggregated updates the served value | folded into the truncation test (447,081 events arrive after the cut) |
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


## Model reconciliation (H2/H3)

Run by `tools/build-model.sh` on every rebuild; it fails loudly rather than printing a warning.

| Test | What it catches |
|---|---|
| Delta serving layer vs interval expansion, **every minute** | any error in hour-clipping, merging or the running sum. Currently PASS on 3,732 minutes, peak 2,917 *(re-run 2026-08-02 on a post-ADR-0009 isolated build; pre-fix it read 3,725 / 2,887)* |
| **Hour-clipping, interior hour** (ADR 0003) | an interval spanning >= 3 hours checked at a minute inside the MIDDLE hour. Worked case: `20:59:48 -> 22:04:49` must emit `+1 @20:59`, `+1 @21:00`, `+1 @22:00`, `-1 @22:05` and NO close in hours 20 or 21 |
| Same-minute interval merge | a session that pauses and resumes inside one minute. 4,797 sessions (44%) hit this; without the merge the delta model double counts and 556 of 1,903 minutes were wrong |

**Anti-pattern that already bit us:** comparing the two models only on minutes where deltas *change*
passes trivially (1,466 minutes, 0 mismatches) while the model is still wrong. The comparison must be
densified with `WITH FILL` so every minute is checked.


## Truncation / open-session absorption (H4/H8)

`tools/truncation-test.sh` · schema in `sql/70_truncation_test.sql` · output `evidence/truncation.txt`

Cuts the stream at the global peak (`2026-07-26 10:56:00`), builds the whole model on the stump,
inserts the withheld 447,081 events as a late arrival, absorbs them by ADR 0006 correction-by-diff,
and compares against a from-scratch build **and** against production, on every minute.

**Runs entirely in the `sonyliv_trunc` database.** `sonyliv` is read with `SELECT` only, and
`assert_isolated()` refuses to execute any templated file naming production as a write target. The
derivation SQL is `sed`-templated out of `sql/30_build_intervals.sql` and `sql/40_deltas.sql` rather
than reimplemented, so the test cannot drift from the model it tests.

| Sub-check | What it catches | Status |
|---|---|---|
| control build vs production, every minute | non-determinism in the derivation | PASS — 2,887 @10:56 and 2,450 @11:10, exact *(measured pre-ADR-0009; those minutes now read 2,917 / 2,483 — see `evidence/reconcile.txt`)* |
| incremental absorption vs control, every minute | anything that makes incremental ≠ rebuild | **FAIL as shipped** — 3 of 1,578 minutes, **+37 at the peak** |
| delta arithmetic isolated from interval state | whether ADR 0006's negate-and-re-emit is itself lossy | PASS — exact on all 1,578 minutes |
| versioned `session_intervals` vs control | that the proposed fix actually fixes it | PASS — row for row identical, converges on all 1,578 minutes |

**The bug this test found.** `session_intervals` is `ReplacingMergeTree(interval_end)`, which resolves
duplicates by keeping the **largest** `interval_end`. `sql/10_intervals.sql` justifies that with "late
heartbeats EXTEND an interval" — i.e. it assumes re-derivation is monotonically increasing. It is not.
A provisional interval carries `TAIL_S = 60s` of grace because its run appeared to end; the completed
derivation places the true end **earlier** (at a pause, or at a real `VideoSessionEnd` inside the
grace window). The stale, longer row then outranks the correct one permanently and drags a stale
`is_open = 1` with it. Measured: **316 intervals up to 60s too long, 315 stuck at `is_open = 1`,
+1.3% on the headline peak.** Fix: a monotonic `build_version UInt64` as the version column.

**Second finding.** `cc_minute_delta.starts`/`ends` are `SimpleAggregateFunction(sum, UInt64)`, so the
negative corrective row ADR 0006 mandates is not representable. ClickHouse does **not** reject it — it
wraps to `2^64 - n`. `sum()` still comes out right by modular arithmetic, but `max()` returns 1.8e19
and any pre-merge single-row read is garbage. Make both `Int64`.

**Anti-patterns specific to this test:**

- **Comparing only the two probe minutes.** The divergence at 10:54 is a single viewer; only the
  all-minutes comparison makes the pattern visible.
- **Rebuilding `cc_minute_delta` during absorption.** That tests nothing — the whole claim is that the
  sealed tier is append-only. The test never truncates it after the stump build.
- **Blaming the diff arithmetic.** Always run the isolation probe before touching ADR 0006; here the
  arithmetic was exact and the fault was two layers upstream.
- **Reading `session_intervals` without `FINAL`.** Pre-merge, the stale and fresh rows are both
  present and every count is doubled.


## Self-observation (H7)

`internal/otelemit`, `internal/pipelinehealth` · `go test ./internal/...` · see
[OBSERVABILITY.md](OBSERVABILITY.md) for what `sonyliv observe` emits and why.

| Test | Proves |
|---|---|
| `TestReadReconcileEvidence_Pass` | the gate-evidence parser reads the REAL box-drawing `evidence/reconcile.txt` format byte-for-byte, including the peak minute (2887 @ 10:56) — not a simplified stand-in |
| `TestReadReconcileEvidence_Mismatch` | a failing gate is surfaced, not averaged away — pinned to the historical `+37 at the peak` defect TESTS.md already documents above |
| `TestReconcileEvidence_PassOnEmptyIsFalse` | a format change that silently parses zero rows cannot read as "everything passed" |
| `TestIntAttrEncodesAsJSONString` | OTLP/HTTP JSON's int64-as-decimal-string mapping is actually followed — a bare `int64` JSON field would lose precision above 2^53 |
| `TestSeverityConstantsAreLowerCase` | `severity:error` saved searches keep matching — HyperDX stores `SeverityText` lower-cased (VERIFIED.md), and this is the one constant a careless edit would recapitalize |
| `TestNewTraceID` / `TestNewSpanID` / `TestNewTraceIDIsRandom` | id shape (16/8 random bytes, lower-case hex) and that two runs do not collide |

**Anti-pattern avoided:** re-deriving build-stage duration or benchmark-query latency by wrapping a
client-side timer around a re-run query. `system.query_log` already has the real, server-measured
number (and `granules_read`/`bytes_read`, which a client cannot know at all) — a client span would
only ever be a strictly worse copy of data ClickHouse already recorded. See OBSERVABILITY.md's
"what is deliberately not instrumented" section.

**Not yet covered by an automated test:** the OTLP emission path itself (`internal/otelemit.Client`)
has no unit test against a fake HTTP server — it was verified by hand against the real ClickStack
collector instead (curl probes, then `sonyliv observe`, then reading the rows back out of
`otel_metrics_gauge`/`otel_logs`/`otel_traces` — see OBSERVABILITY.md). A `httptest.Server`-backed
test for the 401-without-a-key and non-2xx-wraps-body-in-error paths would be the next thing to add
here.
