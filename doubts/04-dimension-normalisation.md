# 04 · Hindi is four strings — is it one language in your answer key, or four?

> **Summary:** `audio_language` carries **41** distinct values and Hindi is **four** of them
> (`hin` 610,889 · `HIN` 69,033 · `hin-hindi` 23,095 · `hin-Hindi` 507). We can serve either reading —
> ADR 0011 keeps the raw strings in storage and normalises on read, so both answers are one `WHERE`
> clause apart. What we **cannot** do is submit both. A benchmark query filtered on Hindi audio
> answers **1,768** un-normalised and **2,180** normalised — a **23.3%** fork on that query, and at the
> graded peak minute `= 'hin'` returns 1,758 of 2,174 Hindi viewers, dropping **19.1%**. The unfiltered
> peak is **2,887 either way**, so nothing else in the model is at risk. **Deepens ADR 0008; answered by
> ADR 0011.**

**Status:** open · **Evidence measured:** 2026-08-01, ClickHouse 26.7.1.1315, local `csv_audit.raw_str`
(verified column-for-column against the CSV with `awk`) and a verbatim rebuild of the committed
derivation (30,769 intervals · 1,949.3 h · peak 2,887)

---

## The evidence

### 1 · Hindi is four strings, and English is four more

```sql
SELECT audio_language AS v, count() AS n
FROM csv_audit.raw_str GROUP BY v ORDER BY n DESC;
```

```
 hin        610,889     HIN     69,033     hin-hindi   23,095    hin-Hindi   507   = 703,524
 eng         77,360     ENG      1,522     eng-english  4,900    eng-English 347   =  84,129
 mal         16,229     MAL      4,284     mal-malayalam  538                      =  21,051

 41 distinct values total.  Japanese is FOUR of them, not two:
   jap 1,374 │ jpn 386 │ JPN 273 │ jpn-japanese 16   = 2,049
 -soundhandler (13) is an ffmpeg handler name, not a language.   '' empty 1,991.
```

`subtitle_language` is 11 values and **91.5% sentinel**:

```sql
SELECT countIf(subtitle_language IN ('UNK','UND','unk','und','')) / count() FROM csv_audit.raw_str;
-- 0.9154488
```

```
 UNK 753,258 │ UND 63,768 │ ENG 29,042 │ off 28,982 │ OFF 10,842 │ unk 9,902
 NON 5,672 │ '' 2,006 │ eng-English 1,375 │ AUT 653 │ und 58
```

### 2 · The fork, measured end to end on the serving layer

Both readings run over the full 28,101-row `cc_minute_delta` rebuilt from the committed pipeline:

```sql
-- reading A — the strings as shipped
SELECT max(c) FROM (
  SELECT minute, sum(sum(delta)) OVER (PARTITION BY toStartOfHour(minute) ORDER BY minute) AS c
  FROM cc_minute_delta WHERE audio_language = 'hin' GROUP BY minute);

-- reading B — case-folded and primary-subtag (ADR 0011's norm_lang)
--   ... WHERE norm_lang(audio_language) = 'hin' ...
```

| | peak Hindi concurrency |
|---|---:|
| **A — `audio_language = 'hin'`** | **1,768** |
| **B — `norm_lang(audio_language) = 'hin'`** | **2,180** |
| difference | **412 viewers, 23.3%** |

At the graded peak minute, 2026-07-26 10:56, of the 2,887 active sessions:

```
 hin 1,758 │ HIN 321 │ hin-hindi 94 │ hin-Hindi 1     = 2,174 Hindi viewers
 `= 'hin'` returns 1,758 of them  →  416 dropped, 19.1%
```

### 3 · The blast radius is exactly one kind of query, and we can prove it

Re-deriving with every dimension value normalised produces **byte-identical** output — 30,769
intervals, 1,949.3 counted watch hours, peak **2,887**. The derivation reads dimensions as labels
only; `ts` drives run splitting and `dim_events` merely tags. So this question **cannot** touch the
headline number, the watch-hours total, or any unfiltered curve. It touches filtered answers and
nothing else.

That is why this is a cheap question to ask and a cheap one to be wrong about — provided we know which
way to answer *before* the benchmark output is generated.

### 4 · Three columns look dirty and are not

Worth stating so mentor time is not spent on them:

```sql
SELECT uniqExact(player_version), uniqExact(lower(player_version)) FROM csv_audit.raw_str;  -- 14, 14
SELECT uniqExact(platform),       uniqExact(lower(platform))       FROM csv_audit.raw_str;  -- 10, 10
SELECT uniqExact(app_version),    uniqExact(lower(app_version))    FROM csv_audit.raw_str;  -- 65, 65
```

`player_version`'s `_ADE`/`_adE` suffixes belong to **different releases** (`3.33.50_ADE` vs
`3.29.71_adE`), so no two values collide under `lower()`. `Mweb` is the only mixed-case platform and
has no twin. The only real `app_version` defect is `5.0.36` (614 rows, 13 sessions) versus
`5.0.36.00` (258 rows, 5 sessions) — same player build `v-0.0.117.12.05.1_adNE`, same platform family
(LG / Samsung HTML TV), almost certainly one release. **872 rows. Small enough to mention, not to ask
about separately.**

---

## Exactly what to ask

> "In the raw file, `audio_language` has 41 distinct values, and Hindi is four of them: `hin`
> (610,889 rows), `HIN` (69,033), `hin-hindi` (23,095) and `hin-Hindi` (507). English is another four,
> Malayalam three, Japanese four (`jap`, `jpn`, `JPN`, `jpn-japanese`).
>
> **The question:** in judge spot-checks, is a query filtered to Hindi audio counting all four
> spellings as one language, or is each string its own filter value?
>
> We ask because we measured both. Treating the four as one gives a peak Hindi concurrency of
> **2,180**; matching the literal string `'hin'` gives **1,768** — a **23.3%** difference on any
> per-language answer. At the peak minute itself, `= 'hin'` returns 1,758 of 2,174 Hindi viewers.
> Our total concurrency is **2,887 either way** — this only affects filtered queries — but if a
> benchmark query filters on language we have to pick one number to submit.
>
> **And a second one, cheaper:** `subtitle_language` is 91.5% sentinel — `UNK` 753,258, `UND` 63,768,
> `off` 28,982, `OFF` 10,842, `NON` 5,672, `AUT` 653, plus 2,006 empty. Do `UNK` and `UND` mean
> different things to you, or are they both just 'not reported'? And should `off` / `NON` / `AUT` be
> read as 'subtitles off', 'none' and 'auto-select' — i.e. real viewer states that belong in a
> breakdown — or as more flavours of missing data?"

---

## Why this is worth mentor time

**Because it is unfittable and it is submitted.** Judge normalization semantics are unspecified; both readings produce
an internally consistent curve, and — critically — **`/reconcile` cannot catch this.** Our gate proves
the serving layer matches our own interval derivation; it recomputes truth from `ev_raw` using the
same strings, so it agrees with itself by construction whichever reading we pick. A 23.3% error on a
filtered benchmark answer passes every test we have.

It is also **cheap to ask and cheap to act on**. ADR 0011 already ships the machinery
(`sql/15_normalise.sql`): the raw values stay in storage and normalisation is a query-time rule, so
switching readings is editing a `WHERE` clause, not rebuilding a model. Measured, the normalised
filter costs nothing — both variants read the same 28,101 rows / 137 KiB, because `audio_language`
sits at sort-key position 7 and never pruned anyway.

The sub-question about sentinels matters less numerically but decides how a chart is *labelled*: if
`UNK` and `UND` are one thing, the subtitle breakdown has one 91.5% bucket; if they are two, it has a
763,160-row bucket and a 63,826-row bucket that mean different things. We currently keep them
distinct and label them with a classifier rather than merging them, which is recoverable either way.

---

## How the answer changes what we build

| If they say | We change | Cost | Effect on the headline |
|---|---|---|---|
| **"four spellings, one language"** | point the benchmark's language-filtered queries at `v_cc_minute_delta_norm` / `v_concurrency_minute_audio_norm` | one `FROM` per affected query — the views already exist | total **2,887 unchanged**; peak Hindi reported as **2,180** |
| **"each string is its own filter value"** | nothing — `cc_minute_delta` already stores raw strings | **zero** | total **2,887 unchanged**; peak Hindi reported as **1,768** |
| **"normalise case but keep `hin-hindi` distinct"** | drop the primary-subtag step, keep `norm_case` — one UDF edit in `sql/15_normalise.sql` | one line | Hindi becomes `hin` 2,079 + `hin-hindi` 95 (audio groups 41→26 instead of 41→18) |
| **"`UNK` and `UND` are the same"** | extend `lang_class` to fold them; the identity function still keeps them apart so it stays reversible | one `multiIf` branch | subtitle breakdown gains one 828,992-row bucket; **no concurrency number moves** |
| **"`off`/`NON`/`AUT` are missing data, not states"** | move them from `off`/`auto` to `unknown` in `lang_class` | one `multiIf` branch | subtitle `off` bucket (peak 130 at the peak minute) folds into `unknown` |
| **"5.0.36 and 5.0.36.00 are one release"** | already handled — `norm_app_version` merges exactly that pair, 65 values → 64 | zero | 872 rows / 18 sessions relabelled; **no concurrency number moves** |
| *no answer received* | **submit the normalised number and show both.** Per-language answers use `norm_lang`; the deck carries the 1,768 / 2,180 pair as a stated sensitivity next to the resume (189.2 h) and unclosed-pause (99.3 h) forks | zero | turns a silent 23.3% risk into a defended trade-off |

**Regardless of the answer**, `v_dimension_drift` runs against the unseen day before any filtered
number is trusted from it — it lists every group carrying more than one spelling, so a new value
family is *seen* rather than assumed absent. That belongs in `docs/RUNBOOK_UNSEEN.md`.

## Our current assumption

Raw strings are stored and never rewritten; normalisation is applied on read
(`sql/15_normalise.sql`, ADR 0011). For a per-language benchmark answer we would report the
**normalised** figure — **2,180** — because four spellings of Hindi are four spellings of Hindi, and
because the un-normalised reading is the one that would look like a bug to a reviewer. **That
preference is a guess, and it is the whole reason this question exists.**

## Answer

_unrecorded_
