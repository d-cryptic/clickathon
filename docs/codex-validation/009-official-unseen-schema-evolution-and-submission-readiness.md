# Codex Validation 009 — official unseen data, schema evolution, and submission readiness

> **Summary:** Re-audited current `main` plus the working changes on 2026-08-02 against every line of all six vendored upstream contracts, the released 7-million-row SonyLIV unseen file, the research branch, the local test corpus, and the updated ClickStack submission rules.
> The ClickHouse-first architecture remains the correct choice; an external Python/Flink preprocessing service is not justified for this batch-plus-incremental workload.
> Landing, per-row cast accounting, semantic quarantine, generic future-column retention, named resolution/show filters, and direct content enrichment are now wired into the model boundary rather than documentation only.
> The fresh official 7-million-row rerun is now green without a partition-setting override: 102 output dates ran as 64+38 chunks, 3,201,716 accepted-input minutes reconciled with zero mismatches, and peak concurrency is 23,324.
> Computational self-reconciliation is strong under the selected policy, but judge spot-checks can still expose foreground-state, heartbeat-only liveness, minute-membership, singleton and session-incarnation semantics.
> The portal closes automatically at **12:00 PM IST on 2026-08-02**; submission is incomplete until the final result/query-log pack, deployed filters, hosted demo, real ClickStack walkthrough/screenshots, 2–3 minute video, pitch PDF, team folder and PR exist.

## 1. Bottom line

The system is a strong ClickHouse solution with a compact and defensible serving model. It is not yet
safe to describe as fully ready for the judges.

| Layer | Verdict | Why |
|---|---|---|
| Lossless ingestion | **Strong** | Header-aware all-String landing, typed/rejected accounting, preserved unknown fields and idempotent load identity are implemented. |
| Cleaning/preprocessing | **Strong structurally; narrow semantically** | Cast failures and unusable session/timestamp rows have terminal states, and both model and gate consume `v_ev_model_input`. Vocabulary/state meaning is intentionally not guessed. |
| Interval/delta mathematics | **Strong under declared policy** | Deterministic intervals, minute-adjacent run merge, hour-clipped signed deltas, distinct-user states and reconciliation are coherent. |
| Official unseen execution | **Local release path green** | 7,000,000 rows loaded; canonical SQL built 102 dates as 64+38 chunks without an override; 3,201,716 minutes reconciled with zero mismatches. A graded-Cloud write was deliberately not performed. |
| Future dimensions | **Good two-lane design** | Every flat unknown column survives in maps and is filterable via a generic fallback; all 12 declared dimensions now have named ClickStack controls in the candidate. Arbitrary new UI controls and fast cubes are not automatic. |
| Real-time updates | **Eventually exact in tested single-writer flow** | Dirty-session publication and correction-by-diff are sound; true multi-host fencing and an event-source offset/id contract are still absent. |
| Judge spot-check accuracy | **Unconfirmed** | The organiser does not define the state/liveness/minute/singleton forks, and session IDs are reused in the official unseen file. |
| Submission evidence | **Incomplete** | Code wiring exists; final live/demo/video/screenshots/package evidence does not. |

**Would I submit it now? Not until the external evidence package is complete.** The official unseen
engineering path is locally green; the remaining score/disqualification risk is deploying and
recording the required ClickStack/filter proof, hosted demo, video, screenshots, deck and team PR.

## 2. Sources and frozen inputs

This audit uses these organiser states:

- problem/unseen repository: `sidagarwal04/click-a-thon-2026@c1e1c698c03c7eea6802f53313f9c005b4892bd6`;
- submission repository: `sidagarwal04/click-a-thon-26-submissions@c446938b0f04064113fcaf2f4f96d64819667689`;
- raw unseen CSV: 1,906,911,465 bytes, 7,000,000 data rows, SHA-256
  `06897bd68b1a5f5729cd1668525c059eb969cfe4e4acdccfe4a6849787775c95`;
- content unseen CSV: 1,442,595 bytes, 33,326 data rows, SHA-256
  `709c36fc9b25a6431dd82fb576b564674700cc717d04cf4d2e4ae8fde5c9daae`.

The six exact contracts are vendored in [`docs/upstream/`](../upstream/). The problem repository's
latest clarification specifies result classes rather than a fixed benchmark SQL set: peak and
average concurrency at minute, hour and day grain with dimension filters. Judges spot-check those
results against raw events. The common submission README's new ClickStack section is also a contract,
not an optional suggestion.

## 3. What the official unseen data actually looks like

The file is not merely the old day with two extra headers.

| Property | Observed value | Design consequence |
|---|---:|---|
| Events | 7,000,000 | Large enough to expose block/partition and expensive fallback-query behaviour. |
| Sessions | 108,486 | Session arrays remain feasible locally, but memory/thread settings still matter. |
| Users | 82,958 | User concurrency must remain a separate exact-set tier. |
| Used content IDs | 15,094 | Real-time content enrichment is cheap against the 33,326-row catalog. |
| Platforms | 21 | Existing named platform filter remains useful. |
| Exact duplicate raw rows | about 24,964 | Dedup policy can affect fine-grained attribution even when the total curve is inert. |
| Sessions without start/play/end | 25,403 / 34,624 / 37,649 | The model cannot depend on a complete lifecycle. |
| App background / foreground events | 14,724 / 8,016 | Explicit state is sparse and asymmetric; absence is not proof of foreground. |
| Multi-start-epoch session IDs | 159 | Grouping only by `video_session_id` can merge separate incarnations. |
| Multi-user/content/platform sessions | 303 / 23 / 448 | `any()` attribution is invalid; deterministic per-interval/run rules are required. |
| Multi-resolution sessions | 93,205 | One session-level resolution label is not credible. |
| Adjacent resolution changes | 440,646 | Resolution is time-varying data, not static metadata. |
| Raw resolution strings | 2,071 | A raw named filter works, but normalization/promotion must be evidence-driven. |
| Empty resolution values | 15,961 | Blank must stay visible rather than silently disappear. |
| Content show names | 360, no blanks | `show_name` is a high-value named content filter. |
| Orphaned content IDs | 0 | The unseen join is complete, but the serving join still preserves future orphans. |
| Adjacent heartbeat gap mode | 40 seconds | Confirms the source cadence and 60-second reporting bucket are different clocks. |
| Heartbeat gaps >60 / >150 seconds | 13,342 / 5,233 | A dynamic timeout learned from one batch would change semantics; keep policy versioned. |
| Same-second heartbeat pairs | 2,027,071 | Millisecond/ordering and same-second tie rules remain load-bearing. |
| Globally / within-session backward adjacent timestamps | 355,121 / 281,502 | Arrival order cannot be treated as event order. |
| Heartbeats while last explicit state is background | 4,656 across 2,422 sessions | Gap-only and state-gated interpretations are genuinely different questions. |
| Uppercase `Pause` | 12 | Event comparison is case-sensitive today; vocabulary drift must be declared or normalized deliberately. |

The typed raw tier covers 189 distinct dates from 2014-12-31. Semantic preprocessing classified the
three 2014/2018/2019 singletons as `ts_out_of_range`, leaving 6,999,997 events across 186 dates from
2020-07-02. Derived intervals/deltas still cover **102 distinct dates** from 2021-01-27 through
2026-08-03, enough to hit the tier insert limit despite the file being described as one unseen day.
Calendar span, populated input dates and output partition count therefore have to be reported
separately.

## 4. Architecture and algorithm evaluation

### 4.1 The core representation is right

The durable pipeline is:

```text
CSV / future transport
  -> immutable all-String landing + load identity
  -> typed raw + cast-rejection ledger
  -> accepted-row view + semantic quarantine
  -> deterministic per-session active intervals
  -> minute-adjacent session runs
  -> hour-clipped signed deltas + exact user states
  -> minute/hour/day and filter serving views
```

This is the correct separation of concerns:

- event-time interpretation happens once before dashboard reads;
- signed deltas make session concurrency O(intervals), not O(session-minutes);
- hour clipping makes each hour independently queryable;
- users use `uniqExact` states instead of summing sessions;
- content metadata remains a query-time dimension, so catalog updates do not rebuild event history;
- arbitrary new dimensions use an exploratory map path, while hot stable fields get promoted.

### 4.2 Sixty-second buckets and forty/sixty-second heartbeats

A report minute is a presentation grain, not a liveness timeout. The system correctly reconstructs
event-time intervals first, then maps them into minute membership. `GAP_S` and `TAIL_S` are versioned
policy, not inferred from each ingestion batch.

The remaining semantic question is which signals count as liveness. The research branch's large
headline change came mainly from requiring heartbeat-only liveness, not from app-state gating:

- current official-unseen diagnostic peak before the final chunk fix: 23,324;
- research state/heartbeat interpretation: 21,509, about 7.8% lower;
- removing only the background gate changed 21,509 to 21,510 and added about 3.38 active hours.

That proves “foreground state” and “heartbeat-only lease” are independent policy axes. Do not adopt
the research number wholesale or describe its 7.8% delta as the cost of backgrounding.

### 4.3 Gaps at scale and in real time

Dashboard read time is the wrong place to sessionize. A materialized view sees only its inserted
block and cannot reliably detect a gap whose previous event lives in an older block. The current
shape is therefore valid:

```text
insert -> MV marks session dirty -> finalizer claims bounded sessions
       -> reorders their complete event history -> derives replacement intervals
       -> publishes signed corrections -> advances a watermark
```

The cost is proportional to touched-session history plus affected serving windows, not total table
history. For bursty ingestion, batch dirty IDs, bound publication by event-time windows, keep one
external fenced publisher lease, and expose queue age/watermark lag. A ClickHouse table lock alone is
not a multi-host fencing token.

### 4.4 The 102-date failure

Daily-partitioned `cc_user_minute` and `cc_minute_delta` reject an INSERT block touching more than the
server's configured partition limit. The current official run failed at user stage with
`TOO_MANY_PARTS`. `SELECT 1 SETTINGS max_partitions_per_insert_block=256` returns Code 452 on the
graded Cloud service because that setting is read-only, so adding `SETTINGS 256` to SQL would turn a
conditional failure into a guaranteed one.

The Cloud-legal fix now executes the canonical SQL40/SQL45 derivations in bounded groups of actual
output dates. `tools/chunked-backfill.sh` enumerates every date touched by accepted intervals and
injects at most 64 dates only at the final output boundary, so multi-day intervals are not cut at the
source. Publisher anchors remain unchanged. `tools/chunked-backfill-test.sh` proves 130 sparse dates,
including a 25-hour interval, become 64/64/2 chunks with exact 1,571 user rows and 285 delta rows.
That release proof is now complete locally: the official file built as 64+38 chunks in each daily
tier and reconciled every accepted-input minute. Cloud legality follows from staying below its
measured immutable cap; no graded-Cloud write was performed in this audit.

## 5. Preprocessing, cleaning, and ETL

### 5.1 What is now good

- The loader reads headers with Python's standard CSV parser. This is a thin control-plane adapter,
  not a row-transformation service.
- All values first land as strings, so one malformed number cannot reject the whole file.
- Numeric parsing produces typed/coalesced/rejected terminal states and preserves raw text.
- Unknown flat columns are stored by name in `extra`; their values also participate in load identity
  and quarantine identity.
- Missing critical identifiers/timestamps refuse before mutation; optional missing columns require an
  explicit flag.
- `q_reason` records unusable session/timestamp rows in `ev_quarantine`.
- The interval builder and independent reconciliation now both consume `v_ev_model_input`.
- Runner accounting asserts `typed + cast-rejected = CSV rows` and `accepted + quarantined = typed`.

### 5.2 What cleaning deliberately does not do

Do not silently lowercase events, merge resolution spellings, rewrite content IDs or learn a gap
threshold from the current batch. Those actions can move judged results. Profile and surface the
drift, then change a versioned policy after an organiser decision.

### 5.3 Do we need Python/Flink/Kafka preprocessing now?

No. Keep the current small Python header/parser step and ClickHouse-native row path. ClickHouse is
already handling landing, type conversion, quarantine, enrichment, interval derivation, aggregation,
serving and observability. A separate row-by-row Python service adds serialization, backpressure,
deployment and dual-definition risk without fixing any current semantic ambiguity.

Add a streaming transport only when the source actually supplies durable offsets/partitions and the
required latency justifies it. Even then, keep the source envelope thin and keep business semantics in
one versioned model rather than duplicating them across Python and SQL.

## 6. New and future columns

The generic design is correctly two-lane:

1. **Fallback lane:** retain every unknown flat header in a `Map`, carry event maps into intervals,
   join content maps into session-minutes, expose dimension-name/value EAV views, and profile coverage
   and cardinality.
2. **Promoted lane:** add a named alias/view/filter or aggregate for fields proven important and
   affordable. The official `video_resolution` and `show_name` fields take this lane.

This means a new column is not lost and is queryable without DDL. It does **not** mean arbitrary new
columns automatically appear as fast dashboard controls. That would be unsafe: high-cardinality maps
can make generic session-minute scans expensive and an unbounded precomputed cube grows
combinatorially.

On the official file, the generic resolution filter is correct at the session-minute membership
grain and additive across resolution buckets. Its value attribution is still a policy: the current
interval model chooses a deterministic modal value, then `v_session_minutes` chooses the latest
touching interval for a session-minute. Direct comparison found 209,778 of 1,370,363 cells (15.31%)
differ from an event-as-of-minute resolution interpretation. The source contract does not choose
first/last/modal/both, so this must be disclosed rather than presented as raw-event spot-check proof.

The fallback is not a primary serving tier at this volume. On the diagnostic current-hash database:

| Shape | Server elapsed | Rows read | Peak memory |
|---|---:|---:|---:|
| total curve | 38 ms | serving-tier read | 0.75 MiB |
| resolution filter | 2.05 s | 18.12 million | 752.51 MiB |
| show filter | 831 ms | 14.79 million | 410.60 MiB |
| resolution + show | 1.66 s | 18.82 million | 753.75 MiB |
| dynamic-key profile | 272 ms | 7,033,326 | 686.30 MiB |

So maps/session-minutes meet the “new field is usable now” goal, while promoted materialized paths
are required for repeatedly used high-cardinality filters.

The current ClickStack candidate now exposes all 12 declared fields: content ID, title, video type,
category, show name, platform, country, app version, audio/subtitle language, player version and video
resolution. Its static contract proves those fields exist in the view, both source select lists and
the hosted filter definitions. This is code readiness, not live evidence; deployment and signed-in
curve verification remain P0.

## 7. Research branch decisions

Do not merge or cherry-pick `origin/feat/problem-space-research@a74b97b` wholesale. Preserve these
ideas:

- separate playing/app state from liveness evidence;
- define session incarnation, not just source session ID;
- store source batch/partition/offset/event identity when the transport provides them;
- stamp model SQL and policy fingerprints on every run;
- make finality/watermark semantics explicit;
- use a real externally fenced publication lease for multiple hosts;
- consider bitemporal/as-of correction only after the contest path is stable.

Reject for now:

- its slower, higher-memory full state query as the primary implementation;
- Python/Flink merely to move preprocessing out of ClickHouse;
- automatic per-batch gap tuning;
- bitemporal storage or an all-dimension cube before a concrete requirement;
- treating research self-reconciliation as proof of the organiser's intended semantics.

## 8. Tests and evidence

The current corpus is materially better than one happy-path file:

| Surface | Current evidence | Interpretation |
|---|---|---|
| Hand-derived edge suite | 32 fixtures | Includes boundaries, users and dynamic-field presence/empty/tie rules. |
| Golden cohorts | 10 pass, 1 known point-activity divergence, 0 unexplained failures in the latest isolated run | Independent expected answers exist, but the one policy fork remains explicit. |
| Partition-safe backfill | Pass: 130 sparse dates in 64/64/2 chunks, exact 1,571 user and 285 delta rows | Proves the Cloud-limit fix includes non-start days of multi-day intervals. |
| ClickStack static contract | Pass: 12/12 declared filters, hosted/self-hosted source PUT convergence, 7-dashboard JSON dry run | Proves committed definitions converge; not a substitute for signed-in live verification. |
| Publisher prior-window test | Pass | A late event recovers history even when the earlier singleton produced no interval. |
| Accepted-row focused smoke | 5 typed rows -> 3 accepted + 2 quarantined; model/gate pass | Proves cleaning is computation, not observability only. |
| Current official run, canonical chunk path | 7,000,000 loaded in 17 s; 6,999,997 accepted + 3 quarantined; 159,426 intervals; 496,631 user buckets; 139,925 deltas; 122,798 hour rows; 3,201,716 minutes; 0 mismatches; peak 23,324 | Local release path passes without a partition-setting override. |
| Same current hash, local override diagnostic | user buckets 496,631; delta rows 139,925; hour rows 122,798; 3,201,716 compared minutes; 0 mismatch; peak 23,324 | Proves downstream logic after the blocker, but the override is forbidden on Cloud and is not a pipeline pass. |
| Dynamic-filter additivity diagnostic | 1,370,363 session-minute rows; total peak = resolution-sum peak = show-sum peak = 23,324; 0 membership mismatches | Proves cell uniqueness/additivity, not the modal resolution policy against organiser semantics. |
| Small generation smoke | 100,000 official rows; four generation gates pass; 54 served resolutions | Proves staging preserves maps; full official generation still depends on the chunk fix. |

Do not use evidence produced while another worktree is dropping the same fixed scratch databases.
Property, landing and truncation artifacts must be regenerated in isolation before being cited. A
green self-reconcile proves implementation coherence under one policy; it does not resolve the
foreground/minute/singleton/session-incarnation policy itself.

## 9. Updated ClickStack submission contract

The official common README now says “we had it running” is not evidence. For ClickStack the final
team folder must contain:

- committed deployment and integration wiring (Compose/Helm, emitter, OTel ingestion, endpoints);
- a secrets-redacted `.env.example`;
- an architecture explanation of what actually flows through ClickStack;
- the exact ClickHouse service and tables receiving its telemetry;
- real dashboard/search screenshots embedded in the submission README;
- a live ClickStack walkthrough in both hosted demo and 2–3 minute video.

The repository already contains most wiring. It must clearly distinguish two paths:

- local all-in-one ClickStack receives OTLP into its bundled ClickHouse tables
  `otel_metrics_gauge`, `otel_logs`, and `otel_traces`;
- hosted HyperDX has no OTLP tables and instead reads the graded `sonyliv` serving views and
  `system.query_log`.

Generated preview PNGs, offline HTML and signed-in query transcripts are valuable supplements. They
do not replace real UI screenshots or the live walkthrough. Langfuse and LibreChat are optional and
should not be bolted on merely because the new section names them.

The official rules require a self-contained team folder and `[Submission] Team Name` PR. They do not
state that this development repository must be public and do not contain a Team Captain-only rule;
older project docs that said so were stale.

## 10. Remaining work, ordered by score/risk

### P0 — before submission

1. ~~Complete the official-file validation through the bounded-date path without overrides.~~
   **Closed locally:** 64+38 date chunks, identical tier counts/peak to the unrestricted diagnostic,
   and 3,201,716-minute reconciliation with zero mismatches.
2. Freeze final official data hashes, Git/SQL/policy fingerprints, answers, query IDs, latency
   distributions, bytes/rows read and `system.query_log`/trace excerpts.
3. Decide or explicitly disclose the session-incarnation, app-state/liveness, minute-membership,
   singleton and resolution-attribution policies. Do not let self-reconciliation stand in for the
   decision.
4. Deploy the current resolution/show filter candidate and verify that both controls affect the
   concurrency curve through the signed-in ClickStack path.
5. Capture actual ClickStack UI screenshots and record the live 2–3 minute walkthrough.
6. Assemble source, README, architecture, hosted demo link, video link and pitch PDF into the official
   team folder and open `[Submission] Team Name`.

### P1 — important architecture closure

1. Introduce an explicit session-incarnation key derived from source identity/start epoch under a
   versioned rule; test the 159 reused IDs independently before changing submitted answers.
2. Add event vocabulary reporting for unknown/case-shifted values such as `Pause` and decide whether
   normalization is contractually valid.
3. Promote only measured hot dynamic dimensions; keep arbitrary maps as a slower drilldown.
4. Add source envelope columns (`ingested_at`, source batch, partition/offset/event ID) when a real
   streaming source exists.
5. Use an external fenced lease if multiple publisher hosts will be allowed.

### P2 — after the contest path is safe

- bitemporal/as-of replay surfaces;
- automatic dashboard-control provisioning after a cardinality/coverage gate;
- separate stream processor only for a demonstrated latency/transport need;
- coarser tier partition migration if long history becomes normal rather than an unseen-file trap.

## 11. Final judgement

The model is generic enough for larger volume and additive flat dimensions without a new service.
It is not generic across unknown business semantics, nor should it pretend to be. ClickHouse can do
the preprocessing and cleaning needed here; the important work is explicit contracts, bounded
orchestration, independent semantic tests and honest evidence.

The 102-date implementation defect is fixed, its focused oracle is green, and the exact official
file completes locally without an illegal setting override. The single thing to close first is now
the **live ClickStack/hosted-demo evidence package**: deploy the current sources and filters, capture
real UI proof, record the 2–3 minute walkthrough, and assemble the official team-folder PR.

## 12. Competition posture and presentation handoff

This is technically winnable: it has a compact ClickHouse-native model, a real correction path,
independent oracles, a hostile official-file run, fast promoted reads, schema evolution and unusually
honest evidence. It is not winner-ready until the live story is as strong as the repository.

Do not add LibreChat or Langfuse merely because they appear in the common README. ClickStack already
satisfies the meaningful-integration requirement. The highest-return order is:

1. deploy the 12-filter ClickStack candidate and verify every control signed in;
2. show total concurrency, then `video_resolution` and `show_name`, then one late-event correction;
3. show the official run: 7 million rows, 64+38 chunks, peak 23,324 and zero reconcile mismatches;
4. explain the two clocks: 40-second heartbeat cadence, 60-second reporting buckets, 150-second
   versioned gap policy;
5. state the semantic risk honestly: explicit background markers are not state gates in the current
   model, and the unseen file contains 4,656 heartbeats while explicitly backgrounded;
6. capture screenshots, hosted link, 2–3 minute video, pitch PDF and the mandatory team PR.

If time remains, a read-only ClickHouse MCP question such as “show the peak and the filters that
explain it” is a useful 15-second flourish. Keep it outside computation. LibreChat/Langfuse is worth
adding only if that assistant is actually part of the live story and its traces are shown; otherwise
it adds integration risk without strengthening a scored requirement.
