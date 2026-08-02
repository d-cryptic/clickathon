# TODOS — the task queue

> **Summary:** Pull from the top. `[H*]` marks the hour block from AGENT_WORKFLOW. Anything blocking
> the `/reconcile` gate outranks everything else. The official unseen release and submission rules
> arrived on 2026-08-02; use Codex Validation 009 for their current P0 queue. Older Cloud counts and
> mentor-era tasks below are retained as engineering history, not the final submission checklist.

## Now

- [x] **[GATE]** **FIXED.** Minutes now DERIVED from ev_raw, dense spine so idle minutes are
      compared, and `minutes_compared` asserted by reconcile.sh. 5 -> **17,028 minutes** on
      production; runs unchanged on the holdout day (1,364 minutes, peak 13). Negative-tested:
      500 fabricated viewers at an IDLE minute now FAILS the gate (25 minutes, max_abs_diff 500)
      where it previously passed. Original text:
- [~] **[GATE]** ~~Fix `sql/90_reconcile.sql`~~ Target minutes were
      2026-07-26 LITERALS: on another day it returns zero rows and `tools/reconcile.sh` prints
      PASSED. It also never compares an IDLE minute (207 of 1,364 on the holdout) — proven by
      fabricating 500 viewers at an idle minute and watching the gate pass. Derive the minutes from
      the data, assert the row count, add a spine. See docs/SESSION-2026-08-01.md §4.
- [x] **[H*]** **Continuously updated aggregates — DONE for all four tiers** (ADR 0013 + ADR 0016).
      `sql/12_publish.sql` + `tools/publish.sh`: an MV marks which sessions each INSERT touched, a
      finalizer re-derives only those and appends `-deltas(old) + deltas(new)`. The one mutation is a
      lightweight `DELETE` pruning superseded interval rows per run. Proven in `evidence/publish.txt` —
      byte-identical to a from-scratch rebuild at every stage, including a straggler 46 min behind the
      watermark corrected with a **flat ~0.3 s delta correction** at every scale measured, plus tier maintenance that scales with audience × window (0.25 s at 1×, 7.3 s at 100×) — ADR 0020. The retired "3.4 s" figure measured the two-tier publisher.
      ADR 0013 alone maintained only `session_intervals` + `cc_minute_delta`, so hour/day peaks went
      stale and user concurrency inflated (a `uniqExact` set union cannot retract). **ADR 0016 closes
      that**: the `hours`/`users` phases re-derive the touched hour-cube rows and user-minute buckets,
      `cc_user_minute` is replace-not-union so retraction is expressible, and `publish-test.sh` now
      compares **all four tiers** across bootstrap, growth, shrink, dimension change, a 46-minute
      straggler and 200 forced republications — 0 differing cells.
      ⚠️ **Installed on `sonyliv` but has never committed a run there** (publish cursor at epoch,
      verified read-only 2026-08-01) — every live number still comes from a batch rebuild. Going live
      is a human's call; see ADR 0013's last section. Follow-ons it deliberately did not do:
  - [ ] **[H*]** Make `session_intervals` a view over an append-only per-run ledger, so the
        per-run lightweight `DELETE` (1.4 s, the dominant cost of a small batch) goes away. Touches
        tables other agents own.
  - [ ] **[H*]** Re-decide the `proj_by_session` projection. Re-measured on the finalizer's actual
        query shape it takes a one-session read from 11.6% of `ev_raw` to **0.9%** (12.8x) for +91%
        storage — the shelved "1.00x" was measured on a shape that full-scanned. Also
        `sql/60_projection.sql` hard-codes `sonyliv.` and cannot be applied elsewhere (same defect
        ADR 0010 fixed in `sql/80_content.sql`).
- [x] **[FIX]** ~~Re-loading the same CSV DOUBLES the data~~ **FIXED** (`6355048`) — `tools/load.sh`
      now REFUSES by default when the tables already hold rows (`MODE=refuse|replace|append`);
      evidence in `evidence/load-guard.txt`.
- [x] **[FIX]** ~~`CH_DATABASE` in the environment is silently ignored~~ **FIXED** (`6355048`) —
      explicit precedence in `internal/config`, the environment wins over `.env`.

- [x] **[H0]** Provision ClickHouse Cloud service; fill `.env`; verify against Cloud
      Cloud is live: db `sonyliv`, schema applied, `sonyliv verify -target cloud` green.
- [x] **[H0]** Datasets into `data/` (`tools/fetch_data.sh`, sha256-pinned); `tools/load.sh`
      Cloud: ev_raw 905,558 · content_dim 33,464 — exact match to source CSVs.
- [x] **[H1]** Confirm the measured shape matches `docs/DATA_DICTIONARY.md` on OUR load
      Reproduced on Cloud: 10,866 sessions · 3,357 content · 10 platforms · bg/fg 14,700/14,321 ·
      span 2026-07-14→26. **One correction:** events are 905,558, not 905,559 (doc counted the header).
- [x] **[H1] GATE ① PASS** — 0.047 beats/min backgrounded vs 4.72/min active (100x drop).
      ADR 0001 stands: gaps detect backgrounding. See [ADR 0007](docs/adr/0007-gate-answers-pause-needs-explicit-handling.md).
- [x] **[H1] GATE ② FAIL** — heartbeats SURVIVE a pause: 0.756/min (16% of active, ~1 event/79s,
      inside any sane gap threshold). Gap-only counts paused time as watching. **Model is now a
      hybrid**: gaps for backgrounding + explicit pause/resume. Fixed in `sql/30_build_intervals.sql`.
- [x] **[H1] GATE ③** — zero events before session_start (no negative skew); 2.2% of sessions emit
      events up to **2,081 s** after VideoSessionEnd. Watermark W >= ~2,100 s.
- [x] **[H2]** `session_intervals` built — `sql/30_build_intervals.sql`. **30,323** intervals over all
      10,866 sessions, 0 invalid. Hand-verified against a raw timeline; reconcile at the peak minute
      gives **2,917** active vs 3,708 naive session-overlap, with 0 unbacked sessions.
      *(Was 30,769 / 2,886 before [ADR 0009](docs/adr/0009-same-second-resume-and-deterministic-attribution.md).)*
- [x] **[H2a]** **Unclosed-pause rule — RESOLVED into a switch.** `UNCLOSED_PAUSE_TO_RUN_END`
      (1 = conservative, shipped; 0 = permissive) in `sql/30_build_intervals.sql` AND
      `sql/90_reconcile.sql` — both, in lockstep. Measured at `cf80acc`: PEAK 2,887 vs 3,018, +4.5% on
      the graded number (hours +5.09%). Gate verified in all three states. Still ask mentor Q2.
      ⚠️ **Both arms predate the ADR 0009 tie fix.** The conservative arm is now PEAK 2,917 /
      1,978.1 h; the permissive arm has **not** been re-run, so the +4.5% / +5.09% spread is stale.
      Deliberately not rescaled — see the new `[H2a-remeasure]` item below. Original:
- [~] **[H2a]** ~~DECIDE~~ unclosed-pause rule. 23% of pauses never resume. Both rules now MEASURED
      end to end: conservative (shipped) 1,949.3 h vs permissive 2,048.6 h — **+99.3 h, 5.09%**.
      The earlier "~19,800 min" estimate was ~3x too high; that time is mostly already excluded by the
      gap rule, the two overlap. Conservative is the safer default for exact raw-event spot-checks.
      **Operator call — see ADR 0007.**
- [ ] **[H2a-remeasure]** **Re-measure the permissive arm on the fixed derivation.** ADR 0009 moved
      the conservative arm (PEAK 2,887 → 2,917, 1,949.3 h → 1,978.1 h) but nothing re-ran
      `UNCLOSED_PAUSE_TO_RUN_END = 0`, so every quoted spread for this switch (+131 viewers, +4.5%,
      +99.3 h, +5.09%) compares two different derivations and cannot be repaired by arithmetic.
      Rebuild with the switch flipped, re-run the gate, and restore the pair. ~20 min. Until then the
      docs carry the `cf80acc` numbers labelled as historical rather than a rescaled guess.

## Next

- [x] **[V2-C1]** **Concurrency-decline alerting — done.** The statement's one optional item
      (`PROBLEM_STATEMENT.md:42`). `tools/clickstack-alerts.sh` + `docs/DECLINE_ALERTING.md`:
      detector (median baseline, lagged 3 min, floored — **28** firing minutes where a naive
      "down 20% in 5 min" fires **962**) and the three-way ended/broken/boring classifier, live as
      3 alerts on hosted HyperDX, watermark-anchored so a frozen dataset is not a contradiction.
      Found and fixed an alert that fired permanently while its tile read 0 (a bare aggregate always
      returns one row; the engine fires on the row, not the value). **Two honest gaps, deliberately
      not tuned away:** `DISENGAGEMENT` is shipped **unvalidated** — no minute in the file exhibits
      it — and the only outage-shaped episode is the file's own truncation at `11:30:04.847`
      (0 unclosed sessions of 10,866, so the strongest outage signature never occurs).
- [ ] **[V2-C1b]** **LLM explanation layer for a fired decline alert** — deliberately NOT in the
      detection path (`DECLINE_ALERTING.md` §6: an LLM there would be slower, non-deterministic and
      would fail *plausibly*). The value is turning the classified row
      (`OUTAGE, 3 min, end_coverage 0.03, hb_per_session 0.07`) into the sentence an on-call engineer
      acts on at 3 a.m. Feed it the **already-classified** row; never let it decide the class, or the
      alert's correctness becomes a function of sampling temperature. Would also give the Langfuse
      Spot Award a real trace to observe (`OBSERVABILITY.md` — one emitter can feed both).
- [x] **[H3]** `cc_minute_delta` hour-clipped (ADR 0003) + `v_concurrency_minute` — **done**.
      `sql/40_deltas.sql`; **28,073** delta rows from **30,323** intervals *(live count re-read
      2026-08-01 after the tier-coherence rebuild; was 28,074 on the prior build)*. Reconcile PASSES on all
      **3,732** minutes against the interval expansion, peak **2,917** both ways *(re-run 2026-08-01)*.
      Serving reads 299 KB vs 2.55 MB for the expansion — 8.5x less I/O, 23 ms *(I/O and latency not
      re-measured at the new row count)*. Rebuild: `tools/build-model.sh`.
- [x] **[H4]** `/reconcile` passing on 5 minutes — **PASSES**. `tools/reconcile.sh` recomputes truth
      from `ev_raw` alone (window functions, not the model's arraySplit) and compares: peak **2,917**,
      both boundaries, two arbitrary — all zero delta. Since `81c0161` it covers **17,028 minutes**,
      0 mismatched. Evidence in `evidence/reconcile.txt`.
      Negative-tested: injecting one bad delta row makes it exit 1.
- [~] **[H4/H8]** Truncation test proving open-session absorption — **built and run**:
      `tools/truncation-test.sh` + `sql/70_truncation_test.sql`, isolated in the `sonyliv_trunc`
      database, evidence in `evidence/truncation.txt`. Cuts the stream at the peak (52.6% of
      sessions open), absorbs 447,081 late events by ADR 0006 correction-by-diff, compares against
      a from-scratch build on every minute. **It does NOT converge as shipped** — +37 on the peak
      minute (2,924 vs 2,887, both as measured at `388a845`, pre-ADR-0009; not re-run). ADR 0006's
      arithmetic is exact; the fault is the version column.
      **Remaining for H4: the finalizer + watermark itself.** Set `W = 2400s` (measured: the 2,081s
      straggler tail binds, not truncation, which only damages the last 60s).
- [x] **[H4-fix]** DONE (388a845) `session_intervals` → `ReplacingMergeTree(build_version)` with a monotonic
      `build_version UInt64`. `ReplacingMergeTree(interval_end)` keeps the LARGEST end, which assumes
      re-derivation only extends; a provisional interval's `TAIL_S=60s` grace can overshoot the true
      end, so the stale row wins forever (316 intervals, 315 stuck at `is_open=1`). Proven to fix it
      in the truncation test. **Schema change — ask the operator before applying to `sonyliv`.**
- [x] **[H4-fix]** DONE (388a845) `cc_minute_delta.starts`/`ends` → `SimpleAggregateFunction(sum, Int64)`. As
      `UInt64` they cannot carry ADR 0006's negative corrective row: ClickHouse wraps it to
      `2^64-n` silently, so `max()` returns 1.8e19 and any pre-merge row read is garbage.
      ← **MVP LINE: sealed tier + stateless baseline is a complete submission from here**
- [x] **[H4]** DONE and MEASURED — verdict: do NOT ship. 27.7x on single-session lookups but the
      real straggler path is `IN (subquery)` which full-scans, so 1.00x for +94% storage.
      `sql/60_projection.sql` kept, deliberately NOT in the build path. Original text:
- [~] **[H4]** `PROJECTION` on `ev_raw` ordered by `video_session_id` — the finalizer and the
      straggler path are point lookups by session, which ADR 0002's key no longer serves. ADR 0002
      names this remedy explicitly. **Measure it; do NOT revert ADR 0002.**
- [ ] **[H5]** Hot tier: `mv_lease` → `cc_minute_hot` (`uniqExact`) + the stitched serving view (ADR 0004/0005)
- [x] **[H6]** DONE — `cc_hour_agg` 8-level cube, 98 hours reconciled 0 mismatches *(26,254 rows on
      the current live build, re-read 2026-08-01; was 26,162 when first shipped)*
- [x] **[H7]** ClickStack up **and** observing us — `make stack-up && make clickstack` charts our
      concurrency views off Cloud (docs/CLICKSTACK.md); `sonyliv observe -target cloud` emits
      watermark lag, build-stage timing and the reconcile gate outcome over OTLP, verified by reading
      the rows back out of `otel_metrics_gauge`/`otel_logs`/`otel_traces` (docs/OBSERVABILITY.md).
      `tools/clickstack-observability.sh` adds the dashboard tiles. Benchmark query latency/bytes is
      deliberately NOT duplicated here — a separate `system.query_log` HyperDX source already covers
      it more accurately than a client span could.
- [ ] **[H8]** Straggler correction-by-diff path (ADR 0006) + the live late-arrival demo
- [ ] **[H8]** Tail-sensitivity sweep (gap × tail grid) — organiser semantics are not fit-able from one file
- [~] **[DIMS]** Filter-dimension value normalisation — **built, wired AND deployed; the decision
      that remains is a mentor's**. `sql/15_normalise.sql` (UDFs + `v_cc_minute_delta_norm`,
      `v_concurrency_minute_audio_norm`, `v_dimension_drift`) and
      [ADR 0011](docs/adr/0011-normalise-filter-dimensions-at-query-time.md). Applied as stage 5/5 of
      `tools/build-model.sh`, and **live on `sonyliv`** since the 2026-08-01 tier-coherence rebuild
      (all 5 UDFs + 4 views verified read-only). Current live pair: raw `hin` peak **1,774 →
      normalised 2,196 (+23.8%)**; total peak **2,917 unchanged**. *(Older pairs — 1,768 → 2,180 at
      `ac04975`, 1,791 → 2,213 quoted earlier on 2026-08-01 — were measured on pre-rebuild models;
      the Codex 002 audit independently measured 1,774 → 2,196 on an isolated current rebuild, which
      matches live.)* Normalising inside the derivation was built and measured as **worse** — 202
      intervals degraded onto a sentinel — so `30_build_intervals.sql` needs no change. **Remaining:**
      (a) decide whether per-language judged queries read the raw column or the normalised view —
      that is [doubts/04](doubts/04-dimension-normalisation.md) / Q18, and it is the only part that
      needs a mentor;
      (b) run `v_dimension_drift` against the unseen day before trusting any filtered number from it
      (belongs in `docs/RUNBOOK_UNSEEN.md`).

## Then

- [x] `/bench` on the full benchmark shapes; capture bytes read — `tools/bench.sh` over the
      13-query reconstructed matrix (`evidence/benchmark/`), evidence in `evidence/bench.txt`:
      bytes/rows read, median-of-3 latency, query_ids, granule pruning, all query-log-auditable
- [x] Minimal concurrency chart — ClickStack/HyperDX over `v_concurrency_minute_total`, no custom
      frontend. Freshness panel added: `tools/clickstack-observability.sh` — watermark lag tile, see
      docs/OBSERVABILITY.md.
- [ ] ADRs for: the `video_session_id` projection, `video_type` materialisation
      (0001–0006 are written; 0001 is **conditional on GATE ①**; 0002 is main's, accepted + measured)
- [x] Deck: 15 slides mapped to the five scoring criteria — `deck/checkpoint1/deck.pdf`, source `deck/checkpoint1/deck.html`,
      regenerate with `deck/checkpoint1/build.sh` (verifies the PDF-only / ≤15 slides / ≤20 MB limits)
- [ ] Rehearse the demo twice

## Blocked / needs a human

- [x] **LICENSE** — restored (MIT, recovered from `fc2c483`). Required submission artifact.
- [ ] **Local container schema drift** — local `cc_minute_stateless.active_state` is
      `AggregateFunction(uniq, …)`; `sql/10_intervals.sql` and Cloud both say `uniqExact` (ADR 0005).
      The local container first-booted before that change and initdb never re-runs. No numeric error
      today (uniq is exact at this cardinality) but the guarantee is absent. Fix needs
      `docker compose down -v` + reload — **operator call, it destroys the local volume.**
- [ ] **ASK A MENTOR** — 16 questions in [docs/MENTOR_QUESTIONS.md](docs/MENTOR_QUESTIONS.md), ranked.
      Tier 1 (Q1 which heartbeats count · Q2 unclosed-pause rule · Q4 session-vs-user · Q5 timezone)
      can invalidate the model, and **none of them are measurable from the data** — judge spot-check
      semantics are not fully specified, so a wrong guess can silently move every answer. Q2 is the
      same decision as `[H2a]`.
      Record answers inline and update the affected ADR in the same commit.
- [ ] **Submission operator** — assemble the self-contained team folder, hosted-demo/video/deck
      links and open the mandatory `[Submission] Team Name` PR. The official rules do not restrict
      this action to a named Team Captain.
