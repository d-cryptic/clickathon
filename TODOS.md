# TODOS — the task queue

> **Summary:** Pull from the top. `[H*]` marks the hour block from AGENT_WORKFLOW. Anything blocking
> the `/reconcile` gate outranks everything else. Keep this file honest — an agent picking up a dead
> session reads it first.

## Now

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
- [x] **[H2]** `session_intervals` built — `sql/30_build_intervals.sql`. 30,769 intervals over all
      10,866 sessions, 0 invalid. Hand-verified against a raw timeline; reconcile at the peak minute
      gives 2,886 active vs 3,708 naive session-overlap, with 0 unbacked sessions.
- [ ] **[H2a]** **DECIDE: unclosed-pause rule.** 23% of pauses never resume. Both rules now MEASURED
      end to end: conservative (shipped) 1,949.3 h vs permissive 2,048.6 h — **+99.3 h, 5.09%**.
      The earlier "~19,800 min" estimate was ~3x too high; that time is mostly already excluded by the
      gap rule, the two overlap. Conservative is the safer default against an exact ground truth.
      **Operator call — see ADR 0007.**

## Next

- [x] **[H3]** `cc_minute_delta` hour-clipped (ADR 0003) + `v_concurrency_minute` — **done**.
      `sql/40_deltas.sql`; 24,958 delta rows from 30,769 intervals. Reconcile PASSES on all 3,725
      minutes against the interval expansion, peak 2,887 both ways. Serving reads 299 KB vs 2.55 MB
      for the expansion — 8.5x less I/O, 23 ms. Rebuild: `tools/build-model.sh`.
- [x] **[H4]** `/reconcile` passing on 5 minutes — **PASSES**. `tools/reconcile.sh` recomputes truth
      from `ev_raw` alone (window functions, not the model's arraySplit) and compares: peak 2,887,
      both boundaries, two arbitrary — all zero delta. Evidence in `evidence/reconcile.txt`.
      Negative-tested: injecting one bad delta row makes it exit 1.
- [~] **[H4/H8]** Truncation test proving open-session absorption — **built and run**:
      `tools/truncation-test.sh` + `sql/70_truncation_test.sql`, isolated in the `sonyliv_trunc`
      database, evidence in `evidence/truncation.txt`. Cuts the stream at the peak (52.6% of
      sessions open), absorbs 447,081 late events by ADR 0006 correction-by-diff, compares against
      a from-scratch build on every minute. **It does NOT converge as shipped** — +37 on the peak
      minute (2,924 vs 2,887). ADR 0006's arithmetic is exact; the fault is the version column.
      **Remaining for H4: the finalizer + watermark itself.** Set `W = 2400s` (measured: the 2,081s
      straggler tail binds, not truncation, which only damages the last 60s).
- [ ] **[H4-fix]** `session_intervals` → `ReplacingMergeTree(build_version)` with a monotonic
      `build_version UInt64`. `ReplacingMergeTree(interval_end)` keeps the LARGEST end, which assumes
      re-derivation only extends; a provisional interval's `TAIL_S=60s` grace can overshoot the true
      end, so the stale row wins forever (316 intervals, 315 stuck at `is_open=1`). Proven to fix it
      in the truncation test. **Schema change — ask the operator before applying to `sonyliv`.**
- [ ] **[H4-fix]** `cc_minute_delta.starts`/`ends` → `SimpleAggregateFunction(sum, Int64)`. As
      `UInt64` they cannot carry ADR 0006's negative corrective row: ClickHouse wraps it to
      `2^64-n` silently, so `max()` returns 1.8e19 and any pre-merge row read is garbage.
      ← **MVP LINE: sealed tier + stateless baseline is a complete submission from here**
- [ ] **[H4]** `PROJECTION` on `ev_raw` ordered by `video_session_id` — the finalizer and the
      straggler path are point lookups by session, which ADR 0002's key no longer serves. ADR 0002
      names this remedy explicitly. **Measure it; do NOT revert ADR 0002.**
- [ ] **[H5]** Hot tier: `mv_lease` → `cc_minute_hot` (`uniqExact`) + the stitched serving view (ADR 0004/0005)
- [ ] **[H6]** `cc_hour_agg` (max + integral); peak/average at minute/hour/day grain with dimension filters
- [~] **[H7]** ClickStack up — **done**: `make stack-up && make clickstack`, HyperDX charts our
      concurrency views off Cloud (see docs/CLICKSTACK.md). **Remaining: instrument watermark lag**,
      not just ingestion lag — nothing of ours emits OTLP yet.
- [ ] **[H8]** Straggler correction-by-diff path (ADR 0006) + the live late-arrival demo
- [ ] **[H8]** Tail-sensitivity sweep (gap × tail grid) — the ground truth is private and unfittable

## Then

- [ ] `/bench` on the full benchmark shapes; capture bytes read
- [x] Minimal concurrency chart — ClickStack/HyperDX over `v_concurrency_minute_total`, no custom
      frontend. Freshness panel still to add.
- [ ] ADRs for: the `video_session_id` projection, `video_type` materialisation
      (0001–0006 are written; 0001 is **conditional on GATE ①**; 0002 is main's, accepted + measured)
- [ ] Deck: 15 slides mapped to the five scoring criteria
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
      can invalidate the model, and **none of them are measurable from the data** — the ground truth is
      private, so a wrong guess is silently wrong on every answer. Q2 is the same decision as `[H2a]`.
      Record answers inline and update the affected ADR in the same commit.
- [ ] **Team Captain** — only they can submit. Confirm who, and that they are awake before the freeze.
