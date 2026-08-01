# Ledger row for `docs/PROMOTION.md` — apply on `dev`

`docs/PROMOTION.md` exists only on `origin/dev`; it is not on `main` and therefore not on this
branch. The W3 row cannot be committed here. Apply this on `dev`:

```diff
-| 3 | ADR 0013 + 0016 publication (one group) | — | |
+| 3 | ADR 0013 + 0016 + 0019 publication (one group) | `GATE 1` | `evidence/promotion/w3/` on `chore/promotion-w3-publication` |
```

And, in the check-5-verdicts section, the W3 entry:

> **W3 publication — DO NOT PROMOTE (failed at check 1, before check 5).** ADR 0019 *had* landed on
> `dev` (`9240ca3`) and is correctly part of the group — the "no unqualified SQL in
> `tools/publish-test.sh`" fix lives in `3ceec7d`, not in `0f89d9d`/`147fd67`, so 0013+0016 without
> 0019 would have re-shipped the 2026-08-02 corruption mechanism. All three of W3's named risk
> checks PASS: `mv_user_minute` is retired (no surviving `CREATE MATERIALIZED VIEW`),
> `cc_user_minute` is `ReplacingMergeTree(computed_at)`, and all 20 write statements in
> `publish-test.sh` are variable-qualified with the extracted SQL run under an explicit
> `?database=`.
>
> **It fails check 1 on three unmet wave-1/wave-2 dependencies**, two of them safety-critical:
> (D1) `publish-test.sh` calls `tools/apply-sql.sh --database` in four places and `main`'s
> `apply-sql.sh` has no option parser, so the convergence claim cannot be re-derived — check 3 never
> ran; (D2) `main`'s `apply-sql.sh` sources `.env` after the caller's environment, so
> `CH_DATABASE=<scratch>` resolves to **`sonyliv`** — there is no safe route to a scratch database on
> this tree at all; (D3) ADR 0016's `build-model.sh` applies `sql/15_normalise.sql` (ADR 0011, wave
> 2), which is absent, so `make model` is broken.
>
> Check 4a PASSES (17,028 · 0 · 0 · peak 2,917). Check 4b reads 177 / 39 / peak 2,887, and the
> attribution was **re-verified independently**: `main`'s gate differs from `dev`'s in three places,
> not two, but patching **only** the two `arrayFirst(x -> x > p, p2.rs)` predicates to `>=` — leaving
> the zero-length-window `arrayFilter` alone — takes it to 0 / 0 / 2,917. So all 177 are `0c0f020`
> and the `arrayFilter` accounts for none.
>
> Check 6 also fails: the retired "3.4 s straggler" figure arrives as a current claim in `TODOS.md`
> and `docs/ARCHITECTURE.md` (×2), because `dev`'s fix `5baeaa9` cites ADR 0020, whose commit
> `535ea96` modifies a `tools/scale-test.sh` that does not exist on `main`.
>
> **This is the sequencing rule this document already states, arriving as a measurement:** *"Wave 2
> is now on the critical path… do not let other waves overtake it."* Promote wave 1, then wave 2,
> then re-run W3.
