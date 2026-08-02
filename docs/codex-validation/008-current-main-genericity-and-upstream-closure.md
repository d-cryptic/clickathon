# Codex Validation 008 — current-main upstream closure, genericity, and live-state audit

> **Superseded on 2026-08-02 by Codex Validation 009.** This is a historical snapshot at `28c7e4a`,
> before the official unseen data, `video_resolution`/`show_name`, accepted-row wiring and updated
> ClickStack submission evidence contract were available. Its “private repository” and “Team
> Captain” blockers were not present in the official submission rules and must not be used.

> **Summary:** Re-audited `main` at `28c7e4a` on 2026-08-02 against every line of all four files in `docs/upstream/`, every tracked repository file, the supplied SonyLIV CSVs in a fresh local ClickHouse database, current test generators, and the live Cloud read path.
> The v2 interval/run/delta algorithm is computationally exact under its declared policy: a fresh 905,558-row load produced 30,323 intervals, peak 2,917, and zero canonical reconcile mismatches.
> It is not yet submission-ready: the live Cloud delta tier is duplicated (56,146 rows and peak 5,834 versus the correct 28,073 and 2,917), the repository is private, and no Team Captain is named.
> The model is generic across event volume and the seven declared dimensions, but only partially generic across new columns, new event vocabularies, arrival transports, and semantic-policy changes.
> Keep preprocessing in ClickHouse; do not add Python to the production row path. The highest-value additions are a generation-pinned serving surface, one versioned policy/config source, one canonical session-run relation, an ingestion envelope, and explicit event-semantics and finality contracts.

## 1. Answer

No: **not everything in the upstream requirements is done and proven yet**.

The right way to state readiness is in three layers:

| Layer | Verdict | Meaning |
|---|---|---|
| Computational correctness | **Strong locally** | Given the repository's chosen rules, the interval model and delta serving curve agree exactly. |
| Semantic correctness | **Partially decided** | Several rules that can move the private score are still assumptions or mentor questions. |
| Operational correctness | **Not ready** | Current Cloud data is doubled, continuous publication is not deployed on the current schema, and current scale/burst evidence is not reproducible. |

The architecture is fundamentally viable. It does not need a Python preprocessing service, a stream
processor, or a different database to solve the stated problem. It does need a small number of
correctness surfaces around the existing ClickHouse model before it can safely accept arbitrary
replays, bursty live ingestion, unseen schemas, and judge queries.

## 2. What this audit actually covered

### 2.1 Repository and data scope

- Managed branch and target branch: `main`.
- Audited commit: `28c7e4a4bdbfb45e1d5a13b78e0dba069ddb525e`.
- The worktree already contained unrelated modified and untracked evidence/tool files. This report did
  not alter them and therefore does not claim that the worktree was clean.
- Read all four upstream files in full, line by line:
  - [`PROBLEM_STATEMENT.md`](../upstream/PROBLEM_STATEMENT.md)
  - [`README.md`](../upstream/README.md)
  - [`README_START_HERE.md`](../upstream/README_START_HERE.md)
  - [`dataset_details.md`](../upstream/dataset_details.md)
- Enumerated all 819 tracked files. A mechanical full-text pass covered 817 text files and 98,920
  text lines. Every requirement-bearing/current architecture/test/status file was then read
  semantically. The two non-text artifacts were inspected separately: the 15-page deck through its
  source plus a rendered PDF page, and the ClickStack dashboard PNG visually.
- Rebuilt from the supplied `data/ch-hackathon-raw-data.csv` and
  `data/ch-hackathon-content-data.csv` into a fresh local database,
  `codex_v2_current_28c7`.
- Re-ran the golden, property, query-robustness, Go, lint, build, shell-syntax, repository-link, and
  documentation-shape checks described below.
- Queried the graded Cloud database read-only. No Cloud table data was written. One
  `SYSTEM FLUSH LOGS` was issued so the already-completed insertion could be identified in
  `system.query_log`.

“Every file” should not be misread as “every historical number is current.” Much of `evidence/`,
`worksheets/`, and old validation reports is intentionally a snapshot from an earlier commit. The
problem is that several active entry documents still quote those snapshots without a current-state
label.

## 3. Upstream requirement closure

Status meanings:

- **PASS** — implemented and freshly verified on current `main`.
- **PARTIAL** — implemented in part, or correct only under a still-open contract.
- **FAIL** — current deployed/runtime state does not satisfy the requirement.
- **UNVERIFIABLE** — private/external evidence was not available.

| Upstream requirement | Status | Current evidence and gap |
|---|---|---|
| ClickHouse is the primary datastore and computation engine | **PASS** | Landing, interval derivation, correction deltas, exact user states, hour/day aggregates, dictionaries, and serving views are ClickHouse-native. Shell orchestrates statements; Python is not the production data path. |
| Meaningful ClickStack integration | **PASS, stale capture** | Six dashboards and 41 tiles exist. The committed screenshot is dated and must not be used as proof of the currently doubled Cloud result. |
| Count foreground-only viewing | **PARTIAL** | Gaps and explicit `event='pause'/'resume'` are modeled. `AppBackgrounded`/`AppForegrounded` are not reliable state transitions in the current model; they contribute timestamps like other events. Private expected semantics remain unknown. |
| Exclude missing-heartbeat periods | **PASS under policy** | Runs split when the event gap is greater than 150 seconds. This tolerates both nominal 60-second and observed 40-second cadence without fitting the threshold to each batch. |
| Exclude paused periods | **PASS under policy** | Explicit lowercase pause/resume windows are removed; an unclosed pause conservatively lasts to run end. Case variants and future event vocabulary are not centrally classified. |
| Active-interval representation | **PASS** | `session_intervals` is the canonical event-time representation and is derived per session. |
| Exact minute peak and average | **PASS locally / FAIL Cloud** | Fresh local peak is 2,917 at 10:56 UTC and the canonical raw-vs-delta gate has zero mismatch. Live Cloud currently serves 5,834 because the delta tier was inserted twice. |
| Hour/day serving | **PASS locally / FAIL as a current deployed system** | The hour-clipped delta and integral design is exact locally. Cloud tiers are not one consistent generation. |
| All seven raw filter dimensions | **PASS in derived rows; PARTIAL in query contract** | `platform`, `app_version`, `country`, `audio_language`, `subtitle_language`, `player_version`, and `content_id` are carried. Sentinel collisions, case handling, unknown values, and alignment errors remain in shipped window queries. |
| Content title/type/category enrichment | **PARTIAL** | Dictionary lookup is a good design for a small mutable catalog, but its 300–600 second lifetime is near-real-time rather than instantaneous. The hostile query suite still finds content/sentinel failures. |
| User-level concurrency | **PASS locally, stale Cloud** | ADR 0031 makes user attribution share the session run rule; fresh output is 91,679 buckets. Cloud still has the earlier 91,692-bucket build. |
| Session-aware versus session-independent comparison | **PASS** | Both curves exist and the supplied data reproduces 2,917 session-aware versus 2,894 stateless peak. |
| Deduplicate repeated/late events | **PARTIAL** | Session re-derivation is idempotent in principle and exact duplicate rows do not normally change set/gap semantics. Raw source identity and replay idempotence are not fully defined; direct repeat insertion into derived additive tables is unsafe. |
| Still-open sessions and late arrivals update continuously | **PASS as repository design / FAIL deployed** | Dirty-session capture plus correction-by-diff is the correct architecture. The current Cloud publisher schema is pre-fencing, has never committed a run, and is incompatible with current `publish.sh`. |
| Rolling and fixed windows | **PARTIAL** | Views exist, but the current hostile suite proves wrong behavior for non-hour-aligned inputs, sentinel-valued real dimensions, and some empty/unknown filters. |
| Watermark and freshness | **PARTIAL** | Publisher lag is exposed. Allowed lateness is still undecided and rows/results are not labeled provisional versus final. |
| New columns / more dimensions | **PARTIAL** | Unknown CSV columns survive in raw `extra Map(String,String)`. They are not carried into intervals, deltas, hour aggregates, user buckets, or generic serving filters. |
| Unseen-day execution | **PARTIAL** | A local synthetic unseen day reconciles exactly. The official runner is Cloud-write-only, omits the normalization/preprocessing SQL, and its cruel-data narratives are stale after recent decisions. |
| 100× scale story | **NOT CURRENTLY VERIFIED** | Historical evidence is directionally useful, but current `tools/scale-test.sh` cannot load the current 5/14-column schemas and ignores those insertion failures. |
| Judge spot-check accuracy and latency | **UNVERIFIABLE AT THAT SNAPSHOT** | The final unseen data and clarified result classes were not yet available. No percentage-accuracy claim was justified. |

## 4. Fresh local results on the supplied dataset

### 4.1 Load and model

| Measurement | Fresh current-main result |
|---|---:|
| Raw events loaded | 905,558 |
| Content rows loaded | 33,464 |
| Rejected/quarantined supplied rows | 0 |
| Sessions | 10,866 |
| Active intervals | 30,323 |
| Counted watch time | 7,121,135 s = 1,978.093056 h |
| Delta rows | 28,073 |
| Delta opens / closes | 20,002 / 16,826 |
| User-minute buckets | 91,679 |
| Session peak | **2,917 at 2026-07-26 10:56 UTC** |
| User peak | **2,844** |

The canonical [`sql/90_reconcile.sql`](../../sql/90_reconcile.sql) result was:

```text
minutes_compared = 17028
mismatched       = 0
max_abs_diff     = 0
peak             = 2917
verdict          = PASS
```

The build wrapper's denser boundary spine reported 17,030 checked minutes, also with zero mismatch.
That two-minute reporting discrepancy does not change correctness, but the evidence surfaces should
use one definition before final submission.

### 4.2 Golden and property tests

The current golden run produced 11 cohorts: 10 PASS, 0 unexpected FAIL, and one declared divergence.
The divergence is important: a session with only one event is expected by the spec-oriented oracle to
receive a 60-second tail, while the shipped `POINT_ACTIVITY_COUNTS=0` model emits no interval.

The current 200-case compatibility property run produced:

| Property | Result |
|---|---:|
| P1 interval/model compatibility | 0 failures |
| P2 ordering/determinism | 0 failures |
| P3–P5 selected adversarial subsets | 0/20 each |
| P6 user/session reference | 3/200 reported |
| P7 repeatability | 0 failures |

The three P6 reports are a **stale oracle**, not three established current-model defects. The property
harness still computes the reference from raw intervals, while [`sql/45_user_concurrency.sql`](../../sql/45_user_concurrency.sql)
now merges minute-adjacent runs and applies first-wins attribution to match the delta tier. The
harness must be updated to the ADR 0031 contract. Current real data retains one cell where users can
legitimately exceed sessions because nine session IDs carry multiple user IDs; silently erasing a user
to satisfy `users <= sessions` would be wrong.

### 4.3 Query-shape robustness

The fresh `query-robustness.sh all` run produced:

```text
PASS          40
LOUD-PASS      6
SILENT-WRONG  22
WRONG          4
```

The main current failures are:

1. [`v_cc_window_range`](../../sql/85_windows.sql) selects sentinel display values from
   `cc_hour_agg` but does not pin `cube_level`. A real platform `*` or real `content_id=-1` collides
   with a roll-up row and corrupts peak/integral results.
2. Top-content queries can duplicate logical keys and cannot represent real `content_id=-1` safely.
3. Two hour query shapes accept non-hour-aligned input but lose carry-in, making all 60 returned
   minutes wrong for the tested case.
4. Unknown/case-variant filters often return plausible empty output rather than an explicit status;
   one empty case returns the Unix epoch.
5. The public parameter contract overloads `*` and `-1` as both real values and “no filter.”

These are query-interface bugs, not failures in interval reconstruction. They still matter to the
private benchmark because the benchmark scores query answers, not only stored intervals.

### 4.4 Code and harness health

- `go vet ./...`: PASS.
- `go test -race -count=1 ./...`: PASS across all five packages.
- `go build ./...`: PASS.
- Pinned `golangci-lint` v2.12.2: 0 issues.
- The default Devbox/make path selects global golangci-lint v1.64.8 and fails the repository's tool
  version gate. The source is clean under the pinned v2 binary, but the advertised one-command gate
  is not portable as currently configured.
- Of 52 shell scripts, only [`tools/spike-test.sh`](../../tools/spike-test.sh) fails syntax under the
  repository's stated macOS Bash 3.2 environment. Therefore the committed burst harness is not a
  current executable proof.
- [`tools/reconcile.sh`](../../tools/reconcile.sh) ignores `CH_DATABASE_LOCAL` in its file-query path
  and queries the default local database. Direct database-pinned SQL passes; the wrapper can falsely
  fail a scratch database.
- The loader's custom-database path can be overridden by `.env`, despite an explicit caller database,
  unless those inherited variables are removed.

## 5. Current Cloud state is a P0 blocker

At the final read in this audit, the current local and Cloud values were:

| Metric | Correct fresh local | Live Cloud |
|---|---:|---:|
| `ev_raw` rows | 905,558 | 905,558 |
| `session_intervals FINAL` | 30,323 | 30,323 |
| `cc_minute_delta` rows | 28,073 | **56,146** |
| total minute peak | 2,917 | **5,834** |
| `cc_user_minute FINAL` buckets | 91,679 | 91,692 |

This is an exact 2× additive-delta duplication. `system.parts` shows a second set of delta parts, and
`system.query_log` identifies query ID `f9781c87-9b14-413a-8fc5-7c052fdcc82e` as a direct execution of
the unguarded `INSERT INTO cc_minute_delta ...` from `sql/40_deltas.sql`, writing 28,073 rows at
2026-08-02 00:33 UTC. This audit does not attribute the caller.

The canonical Cloud reconcile now fails on 3,731 minutes, with raw truth 2,917 and served 5,834 at
the peak. The existing “Cloud gate green” evidence is historical and must not be shown as current.

The deployed publisher objects are also stale:

- the cursor and ingest watermark are at the epoch;
- no publish run has committed;
- deployed `session_dirty` lacks current `insert_id` lineage;
- `cc_publish_consumed` has the earlier key shape;
- `cc_publish_lease` is absent.

Do not repair this by appending another build. Rebuild into an isolated generation, reconcile it,
and promote that generation once. A destructive repair of the graded database needs explicit operator
authorization and is outside this documentation audit.

Two administrative submission blockers are also current:

- GitHub reports `d-cryptic/clickathon` as **PRIVATE**.
- [`SUBMISSION.md`](../../SUBMISSION.md) still has a blank Team Captain field.

## 6. Is the architecture valid?

### 6.1 The core is valid

The current architecture follows the right state boundary:

```text
CSV / live insert
      |
      v
raw events --incremental MV--> dirty session IDs
      |                              |
      +-------- full session read <--+
                                     |
                              explicit finalizer
                                     |
                              session intervals
                                     |
                         minute-adjacent session runs
                           /          |           \
                    signed deltas   exact users   hour/day
                           \          |           /
                              serving/query views
```

Why this is correct:

1. Sessionization depends on prior and future rows for the same session. An incremental materialized
   view sees only the newly inserted block, so it cannot safely build cross-block sessions by itself.
2. An MV is appropriate for **change capture**: `mv_session_dirty` only records which sessions an
   inserted block touched.
3. The finalizer can then re-read each affected session in full, derive its new contribution, and
   publish `new - old` corrections.
4. Hour-clipped signed deltas make each hour independently scanable and preserve exact peak/integral
   arithmetic without expanding every active minute in storage.
5. Exact user concurrency is a set-cardinality question. A replacement state is necessary because
   an append-only union state cannot retract a user after a late correction.
6. Query-time dictionary enrichment is preferable to copying content metadata into an insertion MV:
   a later content update does not retrigger a fact-table MV.

This aligns with current official ClickHouse guidance: incremental MVs process newly inserted blocks,
inserts should be batched, dictionaries are appropriate for small lookup data, and projections should
be driven by measured query shapes rather than added speculatively:

- [Common getting-started issues with ClickHouse](https://clickhouse.com/blog/common-getting-started-issues-with-clickhouse)
- [High-concurrency sizing for user analytics](https://clickhouse.com/resources/engineering/high-concurrency-sizing-user-analytics)
- [ClickHouse query optimisation guide](https://clickhouse.com/resources/engineering/clickhouse-query-optimisation-definitive-guide)
- [Projections and secondary indices](https://clickhouse.com/blog/projections-secondary-indices)

### 6.2 Foreground versus background in this model

“Foreground” is not a source column. It is an inferred state: the session has recent activity and is
not inside an explicit pause window. “Background” means activity should not be counted because the app
is not actively presenting playback; with this dataset it is inferred primarily from heartbeat loss.

The current hybrid is:

- activity events establish liveness;
- a gap greater than 150 seconds ends one active run;
- each run receives at most a 60-second tail after its final active instant;
- explicit `event='pause'` opens a non-counted window;
- explicit `event='resume'` closes it;
- unclosed pauses remain paused to run end;
- `AppBackgrounded` and `AppForegrounded` are not treated as guaranteed state transitions.

That last choice is defensible because upstream explicitly says those events are not guaranteed, and
the delivered stream contains problematic pairing/order. It is not proven to match the private ground
truth. A strict state machine, the current hybrid, and a pure lease model are different semantics and
have materially different outputs.

### 6.3 60 seconds versus 40 seconds

These numbers describe different things and should not be conflated:

- **60 seconds** is the output bucket width and current end-of-run tail.
- Upstream describes heartbeat delivery as nominally once per minute.
- The supplied data contains major substreams with about **40-second** cadence.
- **150 seconds** is the current missing-heartbeat gap threshold.

A 150-second lease tolerates one or two late/missed 40-second heartbeats and also more than two
nominal 60-second periods. It is a policy, not a value that should be re-fitted on every micro-batch.
Changing tail from 60 to 40 seconds moves the supplied result by roughly -1.5% peak and -2.5% watch
hours, so tail and gap must be versioned independently.

### 6.4 What is not generic yet

The algorithm scales across more rows because work is per touched session and serving rows are
interval/delta-shaped. It is not fully generic in these axes:

- exact lowercase pause/resume tokens are embedded in SQL;
- unknown event types still contribute liveness timestamps;
- `VideoError` can therefore extend activity;
- end events do not hard-seal a session because real sessions contain events after ends;
- `session_start_epoch` is stored but does not influence liveness or validate session identity;
- all new CSV columns are retained only in raw `extra`, not in derived filterable state;
- timestamp precision is truncated to whole seconds in core interval math;
- parameter sentinels assume real data will never contain `*` or `-1`;
- the system has no durable source partition/offset or event identity for a true stream;
- multi-tier publication is not exposed as one atomic reader generation.

## 7. Preprocessing: ClickHouse is enough, but the wiring is incomplete

Do **not** introduce Python as a mandatory preprocessing layer before ClickHouse.

The existing direction is appropriate:

- ingest CSV through an all-string landing shape;
- map fields by header name rather than position;
- use `to*OrNull`-style casts and record a cast ledger;
- preserve original/raw values;
- quarantine only unusable identity/timestamp rows;
- expose normalization as deterministic ClickHouse functions/views;
- retain unknown columns in `extra`;
- use a dictionary for content lookup.

The small Python snippets in the shell loader are acceptable control-plane utilities for RFC-4180
header parsing and record counting. Offline Python is also valuable for an independent oracle,
golden-data generation, and property tests. Neither use justifies a Python service in the hot path.

The material current gap is that quarantine is observational, not authoritative:

- [`sql/15_normalise.sql`](../../sql/15_normalise.sql) defines `v_ev_model_input` and reason/flag views;
- interval build, reconcile, and publisher paths still read `ev_raw` directly;
- the unseen runner does not apply/fingerprint `sql/15_normalise.sql`;
- therefore a hostile unusable row can be visible to the model even though a quarantine view says it
  should not be.

Choose one explicit contract:

1. **Enforced quarantine:** every model, gate, and publisher reads the same canonical
   `v_ev_model_input`; or
2. **Observe-only preprocessing:** keep reading `ev_raw`, but stop describing quarantined rows as
   excluded from computation.

For real streaming ingestion, a persistent all-string landing table plus two simple incremental MVs
is reasonable: one `to*OrNull`-validated path into `ev_raw`, one into `ev_rejected` with reason codes.
Those MVs perform row-local routing only; sessionization must remain in the finalizer.

## 8. Realtime, bulk, and bursty ingestion

### 8.1 What exists

- Dirty-session capture is O(rows in the inserted block), reduced to one row per touched session.
- The finalizer re-derives only touched sessions rather than scanning all history.
- A frozen publish batch prevents a session set from changing across phases.
- Correction-by-diff supports late events older than a watermark.
- Replacing tables allow retraction/replacement for interval, user, and hour state.
- The publisher has proposed settle, lookback, lease, and queue-TTL controls.

### 8.2 What is missing

There is no actual source adapter or source-offset contract. The repository demonstrates batch CSV
load and ClickHouse-side incremental maintenance, but not Kafka/ClickPipes/direct-client ownership,
backpressure, poison-message handling, replay boundaries, or end-to-end exactly-once behavior.

For this hackathon, the minimal production path is enough:

- direct batched inserts or ClickHouse async inserts;
- aim for at least 1,000 rows per insert and normally 10,000–100,000;
- on Cloud 26.2, set async-insert behavior explicitly rather than relying on newer defaults;
- use `wait_for_async_insert=1` so acknowledgement means the buffer was flushed;
- provide a stable `insert_deduplication_token` for retried batches;
- store `ingested_at`, batch/source ID, source partition/offset when available, and an event hash or
  event ID.

Dynamic operational values are not fully implemented. Current defaults—150-second gap, 60-second
tail, 5-second settle, 900-second lookback, 60-second lease, and 7-day dirty queue TTL—are duplicated
or fixed in several places. Allowed lateness is still open. The lease does not yet adapt to measured
phase duration, and queue TTL silently becomes the maximum recoverable outage if old dirty markers
expire before consumption.

Do not infer semantic thresholds independently per batch. That makes the same event stream mean
different things on different days and adds a full distribution pass. Instead, publish a versioned
policy selected from measured cadence bands and reject/warn when observed cadence violates the
declared profile.

## 9. Components and surfaces worth adding

These are ordered by correctness value, not novelty.

### P0 — generation-pinned publication

Add a generation identifier to every derived tier and a one-row active-generation control table or
view. A full rebuild writes a new generation, reconciles it, then flips the active pointer. Incremental
publishes expose a committed publish sequence across minute/hour/user tiers.

This solves the failure observed today:

- rerunning a direct additive INSERT cannot silently join the active generation;
- readers do not observe minute, hour, and user tiers from different builds;
- rollback is a pointer change;
- evidence can name the exact generation and policy version it certified.

Shadow tables plus rename are acceptable for one isolated table, but they are not atomic across all
serving tiers. A generation-pinned view is the more generic contract.

### P1 — one versioned model policy

Create one declared policy source for:

- gap threshold;
- tail duration;
- point-activity behavior;
- unclosed-pause behavior;
- minute membership boundary;
- event vocabulary version;
- timestamp precision;
- allowed lateness/finality.

Build SQL, reconcile SQL, publisher templates, golden generators, and result metadata must all name
that version. The fidelity gate should share the declared policy; separate golden/sensitivity tests
must challenge whether the policy is the right one.

### P1 — canonical `v_session_runs`

The minute-delta and user pipelines currently duplicate a load-bearing array fold. ADR 0031 already
records the drift risk. Produce the merged, first-wins attributed run relation once and make both
tiers consume it. This is a correctness refactor, not a performance feature.

### P1 — event-semantics registry

Introduce a small versioned table/dictionary mapping `(event_type, event)` to actions such as
`activity`, `pause`, `resume`, `background`, `foreground`, `terminal`, `ignore`, and `unknown`.
Unknown values must surface as a contract warning/failure, not silently extend liveness. The interval
algorithm can then remain generic when mentors decide how background/end/error events should behave.

### P1 — source ingestion envelope

Add source identity and arrival metadata independently of business event time. Without it, the system
cannot demonstrate arrival ordering, replay ownership, or exactly-once behavior under a real burst.
This is the only additional service boundary required; it can still be a thin producer writing
ClickHouse directly rather than a Python transformation service.

### P1 — explicit query/filter contract

Replace overloaded sentinels with Nullable parameters or explicit `has_platform_filter` flags, pin
`cube_level` on every cubed query, validate hour alignment, and define empty/unknown-filter behavior.
Offer separate exact-range and hour-aligned entry views instead of accepting both through a shape
that is only correct for one.

### P2 — generic cold attributes plus promoted hot dimensions

Carry `extra` as an attribute map and stable attribute hash through interval/run/delta state for an
exact but scan-oriented fallback. Promote only query-log-proven hot keys into typed columns and
appropriate order/projections, rebuilding one generation when promotion changes.

This is the honest way to satisfy “the number of dimensions may increase”: arbitrary keys remain
queryable immediately, while frequently used keys receive an optimized physical shape later.

### P2 — finality views

Once allowed lateness is decided, expose `is_final`, watermark/event-time lag, and policy/generation
metadata with each result. “Continuously updated” without a final/provisional label is ambiguous to a
dashboard consumer.

### Components not to add

- Do not replace session finalization with a plain incremental MV; it cannot see earlier blocks.
- Do not use `AggregatingMergeTree` union states for correctable user buckets; they cannot retract.
- Do not prejoin content metadata into an insertion MV; dimension updates would leave facts stale.
- Do not add a refreshable MV to the core correctness path. It is suitable only for optional periodic
  snapshots/presentation data with a separately declared freshness contract.
- Do not add another projection speculatively. `proj_by_session` already exists in SQL and on Cloud;
  [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) incorrectly says it is not shipped. Measure query-log
  selection before adding more.
- Do not add Python, Flink, or Kafka Streams only to calculate gaps. The explicit finalizer already
  owns the necessary cross-event state in a simpler architecture.

## 10. Semantic uncertainty that can dominate the private score

The exact local reconcile proves implementation agreement, not organizer agreement. Measured
alternatives on the supplied data show the remaining semantic risk:

| Decision/sensitivity | Approximate measured effect |
|---|---:|
| Any-overlap minute versus instant-at-minute | peak about -14.1% |
| Strict state-gated foreground versus current hybrid | historical peak about -10.7%, hours about -13% |
| Same-second resume interpretation | about 9.7% of the headline in the earlier defect sizing |
| No tail after explicit stop-like events | peak about -4.8%, hours about -7.1% |
| Tail 40 s versus 60 s | peak about -1.5%, hours about -2.5% |
| Preserve millisecond precision | peak about -1.8%, hours about -2.6% |
| Event allow-list | peak about -1.3% |
| Point activity enabled | peak +0.34%, hours +0.23% in current SQL |
| Raw versus normalized Hindi filter | filtered answer can move about 23% |

The current entry docs mix two point-activity measurements: toggling the actual SQL adds 16,620
seconds (+4.62 h), while the separate spec interpreter adds 18,127 seconds (+5.04 h). ADR 0031
explains the 1,507-second packing difference and says the relevant minute curve is the same, but
[`README.md`](../../README.md) and [`SUBMISSION.md`](../../SUBMISSION.md) should label the two
experiments rather than presenting them as one number.

Mentor confirmation is still most valuable for:

1. whether a minute means any overlap or activity at one sampling instant;
2. whether background/foreground are authoritative state events or advisory evidence;
3. whether error/end events grant a tail, terminate immediately, or only label the session;
4. whether one observed event earns a tail;
5. allowed lateness and the meaning of final;
6. raw versus canonicalized filter values.

## 11. Documentation and evidence consistency

The repository mentions almost every requested topic somewhere. It does **not** currently present one
coherent current truth.

### Active contradictions/staleness

- `README.md` and `SUBMISSION.md` still describe 82 user/session attribution defects. Current ADR 0031
  fixed 81; the one residual cell has a different multi-user-session cause.
- [`docs/PREPROCESSING.md`](../PREPROCESSING.md) still quotes 91,692 user buckets; current main builds
  91,679.
- Architecture says the session projection is unshipped; it is shipped and live.
- Several active docs say the Cloud gate is green; it is currently red because the delta tier is 2×.
- Historical scale output is presented too close to current proof even though the current generator
  cannot load current schemas.
- [`docs/TESTS.md`](../TESTS.md) does not list the query-robustness suite that currently exposes 26
  wrong/silent-wrong cases.
- Cruel-data expected narratives predate the accepted source-contract and preprocessing changes.
- The unseen runner fingerprints/applies the model without normalization/preprocessing SQL.
- `docs/codex-validation/007-main-submission-audit.md` is a valid historical snapshot at `c642066`,
  not a current-state report.

### Repository hygiene findings

- Of 722 local Markdown links, five unresolved links are intentionally preserved in vendored upstream
  layout and five are real relative-path errors in
  `evidence/promotion/w1/codex-revalidation.md`.
- The “detailed summary in the first seven lines” rule is absent from four first-party active docs:
  `docs/PROBLEM.md`, `docs/design-bakeoff.md`, and the two 2026-08-02 worksheets. Three upstream-owned docs
  also do not follow the local convention and should remain unedited as source material.
- Historical evidence and worksheets need explicit `snapshot commit/date` banners; active entry docs
  need generated current-state blocks rather than copied numbers.

A practical documentation fix is to generate one `docs/CURRENT_STATE.md` from read-only checks:
commit, local generation, Cloud generation, row counts, gate verdict, publisher version/run, policy
version, and evidence age. Other docs can link to it without repeatedly claiming mutable state.

## 12. Ordered closure plan

### P0 — before any submission

1. Rebuild and promote a clean Cloud generation; verify 28,073 deltas and peak 2,917 under the chosen
   policy; rerun raw, user, content, and query-shape gates.
2. Make the repository public and name the Team Captain.
3. Fix the generation/rebuild contract so a repeated build cannot double an additive serving tier.
4. Resolve or explicitly disclose the point-activity decision and the larger foreground semantic
   questions.

### P1 — correctness/readiness

5. Fix sentinel/cube-level and non-aligned range queries, then require the robustness suite in CI.
6. Wire canonical preprocessing input through build, publisher, reconcile, and unseen paths.
7. Centralize policy and session-run logic; update the property oracle.
8. Repair `scale-test.sh`, `spike-test.sh`, `reconcile.sh`, and loader database precedence; generate
   fresh current-commit evidence.
9. Deploy/test the current fenced publisher in a scratch Cloud database before promoting it.
10. Add source arrival identity and explicit batching/async-insert settings for the real ingest path.

### P2 — genericity and operations

11. Carry cold arbitrary attributes into a generic derived/query surface and promote hot dimensions
    from measured query logs.
12. Add final/provisional result labels after lateness is decided.
13. Consolidate current-state documentation and mark historical evidence as snapshots.

## 13. Final judgment

The v2 design is **not a dead end and does not need wholesale replacement**. Its most important
architectural decision—MV for dirty-session capture, explicit session finalizer for cross-block state,
then exact correction deltas—is correct and appropriately ClickHouse-native.

Its present weakness is the contract around that model: mutable serving generations, duplicated
policy and run logic, incomplete preprocessing enforcement, an underspecified ingest envelope, and a
query interface that permits plausible wrong answers. The live 2× Cloud result demonstrates that
these are production correctness issues, not theoretical refinements.

After the P0/P1 items above, the solution can credibly claim exactness under a named policy, safe late
correction, realtime/bursty readiness, and a generic path for future dimensions. Until then, the honest
status is: **locally exact under chosen semantics; partially generic; not currently submission-ready**.
