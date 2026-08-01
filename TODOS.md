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
- [ ] **[H1] GATE ①** Do heartbeats continue while backgrounded? Count beats strictly inside each
      bg→fg pair. **≈0 → ADR 0001 stands. ≈1/min → gaps are blind and the model becomes a hybrid.**
      Nothing past H2 starts until this is answered.
- [ ] **[H1] GATE ②** Census the `event` sub-column for pause states; do heartbeats survive a pause?
      The statement excludes paused time explicitly and we have no handling for it.
- [ ] **[H1] GATE ③** Out-of-order arrival frequency — sets the watermark width `W`.
- [ ] **[H2]** Build `session_intervals` from heartbeat gaps — **one row visible end to end**

## Next

- [ ] **[H3]** `cc_minute_delta` with **hour-clipped** emission (ADR 0003) + `v_concurrency_minute`
- [ ] **[H4]** `/reconcile` passing on 5 minutes — **this is the gate, do not pass it by**
- [ ] **[H4]** Finalizer + watermark; truncation test proving open-session absorption.
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
- [ ] **Team Captain** — only they can submit. Confirm who, and that they are awake before the freeze.
