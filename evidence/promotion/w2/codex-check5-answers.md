# W2 — answering Codex check 5, with the measurement for each finding

> **Summary:** Codex returned **DO NOT PROMOTE** on `7f5a517` and was right. The blocking finding —
> ADR 0009 claims all seven dimensions leave `any()` while `sql/40_deltas.sql` still executed three —
> is closed by cherry-picking `df6e7a2`'s SQL half. **Proven, not asserted:** the pre-fix branch SQL
> rebuilt on a local scratch disagrees with the deployed labels (ANDROID_PHONE 16,357 vs 16,366);
> after the fix it is byte-identical, and all three tier counts equal the graded database exactly
> (30,323 / 28,073 / 26,254). Gates re-run read-only: **4a PASS, 4b PASS, both 17,028 · 0 · 0 ·
> peak 2,917.** `make ci` green. Three documentation findings are also closed. Branch is ready for a
> fresh check 5; it does not promote on this document.

Answered 2026-08-02 from worktree `sc-coupled-squid-f88a`, branch
`chore/promotion-w2-model-correctness`. The verdict answered is
[`codex-validation.md`](codex-validation.md), copied onto this branch so the finding and its answer
sit together.

## The rule this created, and it is applied below

> **A cherry-picked feature is not the ADR that introduced it.** For every ADR on the branch, grep
> the promoted tree for what the ADR *says* is gone and confirm it actually is. Do not trust the
> ADR's own prose — that is precisely what failed here.

Codex did not find a wrong number. It found a **true document describing an untrue tree**: check 1
(isolate) took ADR 0009's derivation fix and left behind the follow-up commit that finished the job,
and check 6 (docs current) read the ADR instead of the SQL.

---

## Finding 1 (BLOCKING) · ADR 0009's `any()` claim was false in the branch's own SQL

**Codex:** `sql/40_deltas.sql` lines 87–89 still execute `any(platform)`, `any(country)`,
`any(content_id)`; they collapse per-interval attribution for 25 live sessions with multiple interval
platforms. Executable, not commentary.

**Answer: fixed.** `df6e7a2`'s `sql/40_deltas.sql` blob is cherry-picked onto this branch. The three
columns now ride the existing `arrayFold` at tail slots `.7/.8/.9` under ADR 0008's
first-wins-per-run rule — reuse, not a third mechanism.

### The blob applied cleanly because the branch was at its exact parent

```text
$ git rev-parse chore/promotion-w2-model-correctness:sql/40_deltas.sql df6e7a2^:sql/40_deltas.sql
7edd79dac003169b280bcd3824f220bd611b58f3
7edd79dac003169b280bcd3824f220bd611b58f3
```

### The `ADR 0012` references were re-pointed, not carried

`df6e7a2` writes both of its halves up as ADR 0012, and `docs/adr/0012-*.md` is **deliberately not on
this branch** — its other half (`tools/build-model.sh` owning every tier it invalidates) is a
separate feature that promotes with wave 3. Promoting the ADR would have repeated the exact defect
this finding is about, in the other direction: an ADR asserting something the tree does not carry. So
the two in-file references now point at ADR 0008 and ADR 0009, which this branch does carry, and the
file states plainly where the rest of `df6e7a2` went.

### Proof that the finding was executable — a before/after scratch rebuild

Two local scratch databases, same `ev_raw` (905,558 rows copied from `default`), same
`sql/30_build_intervals.sql`, differing only in `sql/40_deltas.sql`:

```bash
# BEFORE — the branch's own file at 7f5a517 (the any() version)
git show 7f5a517:sql/40_deltas.sql > /tmp/40_before.sql
docker exec -i ch clickhouse-client --database w2before --multiquery < /tmp/40_before.sql

# AFTER — this branch's file
docker exec -i ch clickhouse-client --database w2ans --multiquery < sql/40_deltas.sql

# both queried with:
SELECT platform, count() AS rows, sum(delta) AS d, sum(starts) AS s
FROM cc_minute_delta GROUP BY platform ORDER BY platform FORMAT TSV
```

| platform | LIVE `sonyliv` | BEFORE (`7f5a517`) | AFTER (this branch) |
|---|---:|---:|---:|
| ANDROID_PHONE | 16,366 | **16,357** | 16,366 |
| ANDROID_TAB | 390 | **400** | 390 |
| FIRE_TV | 317 | 317 | 317 |
| IPHONE | 4,068 | 4,068 | 4,068 |
| JIO_ANDROID_TV | 2,157 | 2,157 | 2,157 |
| LG_HTML_TV | 241 | 241 | 241 |
| Mweb | 783 | 783 | 783 |
| SAMSUNG_HTML_TV | 471 | 471 | 471 |
| SONY_ANDROID_TV | 2,856 | 2,856 | 2,856 |
| XIAOMI_ANDROID_TV | 424 | 424 | 424 |

```text
$ diff live-platform.tsv scratch-platform.tsv
IDENTICAL — branch SQL reproduces the deployed labels exactly

$ diff live-platform.tsv before-platform.tsv
1,2c1,2
< ANDROID_PHONE	16366	2069	12699
< ANDROID_TAB	390	50	223
---
> ANDROID_PHONE	16357	2069	12694
> ANDROID_TAB	400	50	228
```

Read the `sum(delta)` column: **2,069 and 50 in every build.** The rows moved between labels; the
concurrency they carry did not. That is exactly why the unfiltered gate could not see this — and
exactly why "the gate passes" was never an answer to the finding.

### Tier counts now equal the graded database

| tier | live `sonyliv` | BEFORE (`7f5a517` scratch) | AFTER (this branch, scratch `w2ans`) |
|---|---:|---:|---:|
| `session_intervals` | 30,323 | 30,323 | **30,323** |
| `cc_minute_delta` | 28,073 | 28,074 | **28,073** |
| `cc_hour_agg` | 26,254 | 26,242 | **26,254** |

The live column is `docs/PROMOTION.md`'s record of the operator-authorised recovery rebuild. Before
the cherry-pick the branch could not reproduce two of the three; now it reproduces all three.

### Gate against the fixed scratch

```text
   ┌─ord─┬─scope───┬─c1─────────────────────┬─c2───────────┬─c3─────────────┬─c4────────┬─verdict─┐
1. │   0 │ SUMMARY │ minutes_compared=17028 │ mismatched=0 │ max_abs_diff=0 │ peak=2917 │ PASS    │
2. │   2 │ sample  │ 2026-07-14 15:43:00    │ 1            │ 1              │ 0         │ PASS    │
3. │   2 │ sample  │ 2026-07-16 12:35:00    │ 0            │ 0              │ 0         │ PASS    │
4. │   2 │ sample  │ 2026-07-17 08:56:00    │ 0            │ 0              │ 0         │ PASS    │
5. │   2 │ sample  │ 2026-07-26 10:56:00    │ 2917         │ 2917           │ 0         │ PASS    │
6. │   2 │ sample  │ 2026-07-26 11:30:00    │ 197          │ 197            │ 0         │ PASS    │
   └─────┴─────────┴────────────────────────┴──────────────┴────────────────┴───────────┴─────────┘
```

`sql/15_normalise.sql`'s 24-assertion self-test on the same scratch: all zeros.

### What Codex could not reproduce, and why that does not weaken the finding

Codex noted it hashed the live `any()` result identically at `max_threads` 1/8/32 and therefore did
not observe run-to-run variation. `df6e7a2`'s own measurement says the same thing and explains it:
only 25 of 10,866 sessions carry two platforms and none carries two countries or content_ids, so the
groups that *could* vary fit in one block. The identical `any()` over `ev_raw` (905,558 rows, same
`GROUP BY`) returns three different answers at those thread counts. **The non-determinism was latent,
not live — what protected it was the input's shape, not the code.** The label collapse measured above
was live, and it is what the fix removes.

---

## Finding 2 · ADR 0009 contradicted itself

**Codex:** the title and summary claim all seven dimensions left `any()` and determinism is end to
end; the Consequences section admits `sql/40_deltas.sql` reintroduces it. A direct internal
contradiction.

**Answer: closed.** The `sql/40_deltas.sql` Consequences bullet is rewritten from "**Filed, not
fixed**" to a record of the closure — what was wrong, that Codex caught it, what the fix reuses, what
it measurably moved (13 of 17,189 merged runs relabelled; peak 2,917 and 1,978.1 h unmoved;
`cc_minute_delta` 28,074 → 28,073), and an honest statement that the determinism half was latent
rather than live. The title is now true of the tree.

The `tools/build-model.sh` "Filed, not fixed" bullet is **left standing**, and correctly: that file
is not on this branch, so the ADR filing it as open is an accurate statement of this tree.

---

## Finding 3 · The 2,697 numerator overstates model impact

**Codex:** 2,697/27,340 (9.86%) holds as a raw event-row rate but not as independently affected pause
instants — 27,340 rows collapse to 27,017 distinct `(session, second)` instants, of which 2,502
(9.15%) carry the tie. The raw ledger moves 39.8 h deduplicated, not 41.5 h, and end to end the model
moves 28.8 h. This also explains the conflict with `origin/dev`'s `docs/PROMOTION.md`, which says
2,502/27,340.

**Answer: accepted and qualified.** Both numerators are now in ADR 0009's summary and measurement
table with the rule for which to use: **9.15% when describing what the model saw, 9.86% as a raw
event-row rate.** The 41.5 h figure keeps its explicit "raw pause-ledger" label and now carries the
deduplicated 39.8 h and the end-to-end +28.8 h beside it, so the three cannot be swapped for each
other. `evidence/promotion/w2/README.md`'s check-3 table carries the same qualification.

Note what did *not* change: no measurement was wrong. ADR 0009's body already called 41.5 h a raw
figure and already gave a narrower 23.3 h in-run figure. The defect was that a reader — including the
promotion brief — could take the headline as model impact.

---

## Finding 4 · ADR 0014 was Accepted while three sites still carried a bare `argMax`

**Codex:** `sql/90_reconcile.sql:216` and `tools/unseen-run.sh:307,312` retain
`argMax(minute, …)` / `argMax(peak_minute, peak)`. The promotion evidence discloses them as
unapplied, but that conflicts with the ADR's Accepted status and "earliest wins, everywhere".

**Answer: half fixed, half named.** This branch carries `sql/90_reconcile.sql`, so ADR 0014 inventory
row 12 is now **applied**, using the ADR's own committed diff sketch:

```diff
-            (SELECT argMax(minute, truth) FROM compared),
+            -- ADR 0014: earliest minute at the peak, so the sampled minute is
+            -- the same on every run and the committed evidence is reproducible.
+            (SELECT argMax(minute, (truth, -toInt64(toUInt32(minute)))) FROM compared),
```

Verified verdict-neutral — the gate output is byte-identical against both the live service and the
scratch, because `max(truth)` = 2,917 is unique on the provided file. It is a correctness fix on any
day it is not.

Rows 10–11 (`tools/unseen-run.sh`) are **not** applied: that file is not in this branch's diff and is
owned by another workstream. Row 11 is the submitted answer path, so it matters; ADR 0014 now carries
a dated addendum stating per-site exactly what is applied and what is not, so its Accepted status no
longer over-claims. The addendum names row 11 as the open item.

---

## Finding 5 · `docs/RUNBOOK_UNSEEN.md`'s first seven lines contradicted the branch's own gate

**Codex:** the summary says the committed gate "does NOT work on a new day — its five target minutes
are 2026-07-26 literals, so it returns zero rows and `tools/reconcile.sh` reports PASS having compared
nothing", while `sql/90_reconcile.sql` on the same branch derives its samples from the data. The file
is in W2's diff, so check 6 cannot dismiss it as an untouched historical record.

**Answer: closed.** Commit `81c0161` ("the reconcile gate now checks every minute and re-targets
itself") closed three defects before this promotion existed, and the gate's own header says so:

- samples DERIVED from `compared` — peak, both data boundaries, two by `cityHash64`
- a dense `spine` CTE over every minute between the first and last `ev_raw` event, so an idle minute
  is compared as `0 = 0`; `compared` is `FROM served LEFT JOIN truth_min`, not the other way round
- a `SUMMARY` first row carrying `minutes_compared`, which `reconcile.sh` fails on if it is zero

The runbook's summary, §A1, §A2, the "G0 prints ZERO ROWS" troubleshooting row and §4.1 are all
corrected, with A1 and A2 marked **CLOSED by `81c0161`** and kept as history rather than deleted.

**Named, not fixed:** `tools/unseen-run.sh:31,331–337` still *narrates* the literals story and still
warns about a vacuous G0 pass. Those strings are stale. That file is not in this diff — same owner as
the ADR 0014 rows 10–11 — and the runbook now says so explicitly, so the next person to touch
`unseen-run.sh` can close both in one pass.

---

## Finding 6 · The branch carried an obsolete promotion contract

**Codex:** branch `docs/PROMOTION.md` still had the one-part check 4 and `claude-fable-5` as the
check-5 validator, while the gates were actually run under `origin/dev`'s revised two-part check 4
with a Codex validator.

**Answer: closed.** `docs/PROMOTION.md` is replaced with `origin/dev`'s current version — the
two-part check 4a/4b, the Codex-lineage check 5, the 2026-08-02 incident record and the check-5
verdict section — with the ledger updated for what this branch has now answered.

---

## Check 4 re-run, read-only, after every change above

Command (credentials stayed environment variables, sourced from the main checkout's `.env`; both SQL
files were scanned for `INSERT/UPDATE/DELETE/ALTER/CREATE/DROP/TRUNCATE/OPTIMIZE/RENAME/REPLACE/
DETACH/ATTACH/EXCHANGE` first — no matches in either):

```bash
h="${CH_HOST#https://}"; h="${h%/}"
curl -sS --fail-with-body \
  "https://${h}:${CH_PORT}/?database=${CH_DATABASE}&default_format=PrettyCompact" \
  --user "${CH_USER}:${CH_PASSWORD}" --data-binary @<gate.sql>
```

### 4a — `origin/dev`'s gate against the graded database

```text
   ┌─ord─┬─scope───┬─c1─────────────────────┬─c2───────────┬─c3─────────────┬─c4────────┬─verdict─┐
1. │   0 │ SUMMARY │ minutes_compared=17028 │ mismatched=0 │ max_abs_diff=0 │ peak=2917 │ PASS    │
2. │   2 │ sample  │ 2026-07-14 15:43:00    │ 1            │ 1              │ 0         │ PASS    │
3. │   2 │ sample  │ 2026-07-16 12:35:00    │ 0            │ 0              │ 0         │ PASS    │
4. │   2 │ sample  │ 2026-07-17 08:56:00    │ 0            │ 0              │ 0         │ PASS    │
5. │   2 │ sample  │ 2026-07-26 10:56:00    │ 2917         │ 2917           │ 0         │ PASS    │
6. │   2 │ sample  │ 2026-07-26 11:30:00    │ 197          │ 197            │ 0         │ PASS    │
   └─────┴─────────┴────────────────────────┴──────────────┴────────────────┴───────────┴─────────┘
```

### 4b — this branch's own gate against the graded database

```text
   ┌─ord─┬─scope───┬─c1─────────────────────┬─c2───────────┬─c3─────────────┬─c4────────┬─verdict─┐
1. │   0 │ SUMMARY │ minutes_compared=17028 │ mismatched=0 │ max_abs_diff=0 │ peak=2917 │ PASS    │
2. │   2 │ sample  │ 2026-07-14 15:43:00    │ 1            │ 1              │ 0         │ PASS    │
3. │   2 │ sample  │ 2026-07-16 12:35:00    │ 0            │ 0              │ 0         │ PASS    │
4. │   2 │ sample  │ 2026-07-17 08:56:00    │ 0            │ 0              │ 0         │ PASS    │
5. │   2 │ sample  │ 2026-07-26 10:56:00    │ 2917         │ 2917           │ 0         │ PASS    │
6. │   2 │ sample  │ 2026-07-26 11:30:00    │ 197          │ 197            │ 0         │ PASS    │
   └─────┴─────────┴────────────────────────┴──────────────┴────────────────┴───────────┴─────────┘
```

The two gate files now differ **only** by ADR 0014's three-line sample-picker change:

```text
$ diff <(git show origin/dev:sql/90_reconcile.sql) sql/90_reconcile.sql
216c216,218
<             (SELECT argMax(minute, truth) FROM compared),
---
>             -- ADR 0014: earliest minute at the peak, so the sampled minute is
>             -- the same on every run and the committed evidence is reproducible.
>             (SELECT argMax(minute, (truth, -toInt64(toUInt32(minute)))) FROM compared),
```

**There is no spec skew on W2 and no excuse to make**, which is what the brief required of 4b here.

## The ADR-vs-tree grep, run rather than assumed

```text
$ grep -rnE '\bany\(' sql/                       # executable any() anywhere in sql/
sql/30_build_intervals.sql:106,113,280,291       — all inside -- comments
sql/10_intervals.sql:59                          — inside a -- comment
[no executable any() remains]

$ grep -nE 'x -> x >=? p' sql/30_build_intervals.sql sql/90_reconcile.sql
sql/30_build_intervals.sql:197  x -> x >= p, resumes     ← ADR 0009's inclusive close
sql/30_build_intervals.sql:201  x -> x > p, run   (×2)   ← ADR 0009 says this one STAYS strict
sql/30_build_intervals.sql:202  x -> x >= p, resumes
sql/90_reconcile.sql:118        x -> x >= p, p2.rs       ← the gate carries the same spec
sql/90_reconcile.sql:121        x -> x > p, r.run_ts     ← strict, as specified
sql/90_reconcile.sql:122        x -> x >= p, p2.rs

$ grep -rnE 'argMax\(\s*minute\s*,\s*[A-Za-z_]' sql/ tools/
sql/85_windows.sql:47            — inside a -- comment
tools/unseen-run.sh:312          — ADR 0014 row 11, NOT carried by this branch, named as open
[sql/90_reconcile.sql no longer matches: applied]

$ grep -nE 'CREATE (OR REPLACE )?(FUNCTION|VIEW)' sql/15_normalise.sql
5 UDFs + 4 views — matching the 5 SQLUserDefined functions and 4 Views live on sonyliv
```

## `make ci`

```text
go mod tidy · go vet ./... · golangci-lint run ./...  → 0 issues
CGO_ENABLED=1 go test -race -count=1 ./...
  internal/config          ok 1.546s
  internal/otelemit        ok 2.389s
  internal/pipelinehealth  ok 1.966s
go build -trimpath ... -o bin/sonyliv ./cmd/sonyliv   → ok
```

## Rules held while answering

No write of any kind reached `sonyliv` or any Cloud database. `REBUILD_GRADED` and
`APPLY_GRADED_DESTRUCTIVE` were never set, not even to test that a guard refuses. Both scratch
databases (`w2ans`, `w2before`) live on the local `ch` container. Every Cloud statement was scanned
for write forms before being sent, and credentials were read from the main checkout's `.env` into
environment variables — never copied, never printed.
