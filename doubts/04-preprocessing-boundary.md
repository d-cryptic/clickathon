# 04 · Where does "handle erroneous data" stop? Normalisation vs. matching the shipped strings

> **Summary:** The mentor's answer to [doubt 03](03-content-catalog.md#answer) — handle empty strings,
> nulls and duplication in a **pre-processing stage before joins/MVs** — collides head-on with a
> deliberate, measured policy this repo already ships: **raw values, never canonicalised**, because
> the private ground truth is matched on the shipped strings (ADR 0008, `sql/30_build_intervals.sql`).
> The collision is not hypothetical: `audio_language` has **41 raw values that collapse to 26**
> case-insensitively, Hindi alone is split across `hin` (610,889), `HIN` (69,033) and `hin-hindi`
> (23,095) — **703,017 events, 77.6% of the file, under three labels for one language** — and
> `subtitle_language` carries `off` (28,982) vs `OFF` (10,842) plus an 83% `UNK` sentinel. If
> "erroneous" includes case variants and alias forms, every filtered benchmark answer moves; if it
> only means empty/null/duplicate, the pre-processing stage is small. We cannot tell which from the
> answer we got. **Follow-up to doubt 03's recorded answer; deepens ADR 0008.**

**Status:** open · **Evidence measured:** 2026-08-01, local `csv_audit.raw_str`, fresh CSV load,
905,558 rows

---

## The evidence

### 1 · The dimension vocabulary is dirty in *four different ways*, not one

```sql
SELECT col, uniqExact(v) AS raw, uniqExact(lower(v)) AS folded ...  -- per dimension column
```

| column | raw values | case-folded | collisions |
|---|---|---|---|
| `audio_language` | **41** | **26** | 15 |
| `subtitle_language` | **11** | **8** | 3 |
| `platform` | 10 | 10 | 0 |
| `country` | 1 | 1 | 0 |
| `app_version` | 65 | 65 | 0 |
| `player_version` | 14 | 14 | 0 |

The dirt is confined to the two language dimensions — and `dataset_details.md` names both as filter
dimensions.

### 2 · Four distinct kinds of "erroneous", with measured sizes

```sql
SELECT audio_language, count() FROM csv_audit.raw_str GROUP BY 1 ORDER BY 2 DESC;
```

| kind | example | events |
|---|---|---|
| **empty string** | `audio_language = ''` 1,991 · `subtitle_language` 2,006 · `player_version` 1,534 | 5,531 |
| **case variant** | `hin` 610,889 vs `HIN` 69,033 · `off` 28,982 vs `OFF` 10,842 · `mal`/`MAL`, `tel`/`TEL`, `unk`/`UNK`… | ~120k |
| **alias form** | `hin-hindi` 23,095 · `eng-english` 4,900 · `eng-English` 1,375 | ~29k |
| **sentinel** | `unk`+`UNK` 51,185 audio · `UNK` 753,258 + `UND` 63,768 subtitle | up to 83% of a column |

Hindi as a viewer would understand it — `hin` + `HIN` + `hin-hindi` — is **703,017 events (77.6%)**
currently reported under three different labels. A benchmark filter `audio_language = 'hin'` misses
92,128 of them (10.2% of the file) if the key normalised and we did not; conversely a normalising
pre-processing stage answers wrongly if the key is raw.

### 3 · What the repo currently does, on purpose

`sql/30_build_intervals.sql` (per-interval dimension attribution, ADR 0008):

> "Raw values, never canonicalised — 'HIN' and 'hin' stay distinct because the private ground truth
> is matched on the shipped strings, not on our idea of tidy ones."

That policy was chosen *before* the mentor said erroneous data must be pre-processed. Both cannot be
fully right. Duplication is already settled — measured inert, and the mentor wants dedup anyway
(doubt 03). Empty strings are settled — relabel to `'unknown'` (doubt 03's answer). **Case variants,
alias forms and sentinels are the unresolved middle**, and they are 100× larger than the empties.

### 4 · The one duplicate group that is not byte-identical is *in* this middle

```sql
-- group by (video_session_id, event, event_timestamp) HAVING count() > 1
identical_groups: 3,412    differing_groups: 1
example: session 4C5EE2…E29E, subtitle_language ['UNK','OFF']
```

Dedup needs a winner rule for exactly this row, and the winner rule is a normalisation decision:
`UNK` (sentinel) vs `OFF` (meaningful). Dedup and normalisation cannot be designed independently.

---

## Exactly what to ask

> "You told us to handle erroneous data — empty strings, nulls, duplicates — in a pre-processing
> stage before joins and materialised views. We've scoped that, and there's one boundary we can't
> place without you: **does 'erroneous' include inconsistent labels, or only structural defects?**
>
> Concretely: `audio_language` in the shipped file has 41 distinct values. `hin`, `HIN` and
> `hin-hindi` together are 703,017 events — 77.6% of the file — that are presumably all Hindi.
> `subtitle_language` has both `off` and `OFF`, and a `UNK` sentinel on 83% of rows.
>
> **Question one:** when a benchmark query filters or groups by audio language, does the answer key
> use the raw shipped strings — `hin` and `HIN` as two buckets — or normalised values? If normalised,
> what is the rule: lowercase? strip the `-hindi` suffix? Is `unk` merged with the empty string?
>
> **Question two:** for the one duplicate pair that differs only in `subtitle_language`
> (`UNK` vs `OFF`), which row survives dedup?
>
> We ask because the two readings move 10.2% of events between buckets on the biggest language
> filter, and we'd rather implement your normalisation rule than invent one."

---

## Why this is worth mentor time

The answer to doubt 03 obligates a pre-processing stage; this question decides **how big it is and
what it touches**. Guessed wrong in either direction it is silently wrong on every language-filtered
benchmark answer: normalise when the key is raw and `hin` vs `HIN` answers merge that should not;
stay raw when the key is normalised and every Hindi filter under-reports by 10.2%. Nothing in
`/reconcile` can catch it — the gate compares our serving layer to our own derivation, both on the
same strings.

## How the answer changes what we build

| If they say | We change | Cost |
|---|---|---|
| **"erroneous = structural only (empty/null/dup)"** | pre-processing stage stays small: dedup + `''`→`'unknown'` + quarantine. ADR 0008's raw-string policy stands for case/alias/sentinel | the doubt-03 work item as scoped, nothing more |
| **"normalise labels too, rule: X"** | add the stated rule (e.g. lowercase + alias map + sentinel merge) to the same pre-processing stage; rebuild; ADR 0008 amended — attribution now runs on cleaned values | one normalisation map + full rebuild + `/reconcile`; every language-filtered number re-measured |
| **"answer key groups by raw strings"** | keep raw values in the model; pre-processing normalises *copies* into `*_clean` columns for dashboards only, graded answers stay raw | two columns, no model change |
| **"dedup winner: keep first / keep OFF / keep UNK"** | encode that exact rule in the dedup stage | one `ORDER BY` in the dedup key |
| *no answer received* | implement structural-only (smallest defensible reading of the recorded answer), keep raw labels for graded output, ship a documented `v_*_normalized` view family alongside, and state the 10.2% sensitivity in the deck | small; both readings stay servable |

## Our current assumption

The mentor's "erroneous data" means **structural defects only** — empty strings, nulls, duplicates —
per the literal words recorded in doubt 03. Labels stay raw for graded answers (ADR 0008 stands).
**Confidence is low**: the same conversation could reasonably be read as "clean the data properly",
which includes the 41→26 collapse.

## Answer

_unrecorded_
