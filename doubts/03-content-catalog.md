# 03 · The content catalog — a nameless third `video_type`, titles that are not keys, and a planted id

> **Summary:** Three findings in `ch-hackathon-content-data.csv` that decide how content-level answers
> are **labelled** rather than whether they are arithmetically right. **(a)** `video_type` has a third
> value — the empty string — covering 1,089 catalog rows and **25,810 events (2.85%)**, so any
> `GROUP BY video_type` gets a blank bucket and any `WHERE video_type IN ('vod','live')` silently drops
> those events. **(b)** `title` is **not a key**: 2,773 titles are shared by 2–4 distinct `content_id`s
> and 1,418 of those collisions span *different categories*, so our `v_concurrency_minute_title` view
> merges distinct assets under one name. **(c)** exactly one catalog row carries a **negative**
> `content_id` (`-987654322`) with zero events — a planted poison row that kills a `UInt64` column.
> All three are cheap to handle now and expensive to discover on the unseen day.

**Status:** ANSWERED 2026-08-01 — see [Answer](#answer) · **Evidence measured:** 2026-08-01, local
`csv_audit.content_str` (33,464 rows) and `csv_audit.raw_str` (905,558 rows), fresh CSV load ·
**Re-verified 2026-08-01 (second load):** every number in this file reproduced exactly

---

## The evidence

### 0 · The catalog is clean where it matters

```sql
SELECT count(), uniqExact(content_id) FROM csv_audit.content_str;          -- 33,464 / 33,464
```

`content_id` is a **true primary key** — no duplicates — so `content_id → title / category /
video_type` is strictly many-to-one and deterministic. No content_id carries two different titles.

And the join is currently loss-free:

```sql
SELECT uniqExact(r.content_id), sum(r.cnt)
FROM (SELECT content_id, count() AS cnt FROM csv_audit.raw_str GROUP BY content_id) r
LEFT ANTI JOIN csv_audit.content_str c ON r.content_id = c.content_id;     -- 0, 0
```

**0 orphan content_ids, 0 orphan events.** Every event's `content_id` has a catalog row, so `INNER
JOIN` and `LEFT JOIN` return identical results on this file — 905,558 either way. *That is a property
of this file, not a contract.*

Also worth knowing: only **3,357 of 33,464** catalog rows (10%) are ever referenced. 90% is dead
weight today, and the live set will be entirely different on the unseen day.

### (a) `video_type` has a third, nameless value

```sql
SELECT video_type, count() FROM csv_audit.content_str GROUP BY video_type ORDER BY count() DESC;
```

| value | catalog rows | share |
|---|---|---|
| `vod` | 32,182 | 96.17% |
| **`''` (empty)** | **1,089** | **3.25%** |
| `live` | 193 | 0.58% |

Joined through to events: **25,810 events (2.85%)** across **142 distinct content_ids** land on the
empty bucket, against 778,455 `vod` and 101,293 `live`.

`sql/80_content.sql` already notes the blank exists and deliberately leaves it as-is, reasoning that
`dictGet`'s `'(unknown)'` default fires only on a **key miss**, not on an empty **source value** — so
an empty `video_type` surfaces as `''`, which is real source data rather than a join failure. That
reasoning is correct. What is missing is the *number*, and the decision about how it is labelled to a
judge or a dashboard.

### (b) `title` is not a key

```sql
SELECT countIf(n > 1) AS colliding_titles, max(n) AS max_fan_in
FROM (SELECT title, uniqExact(content_id) AS n FROM csv_audit.content_str GROUP BY title);
```

```
 33,464 content_ids  →  30,508 distinct titles

 2,773 titles are shared by MORE THAN ONE content_id
   ├─ 2,596 shared by 2 ids
   ├─   171 shared by 3 ids
   └─     6 shared by 4 ids

 of those collisions:  1,418 span MULTIPLE CATEGORIES
                         198 span MULTIPLE VIDEO_TYPES

 worked example — title "fawow kig" maps to four ids:
   [2048998936, 2078166911, 2078163746, 21171116]
```

`sql/80_content.sql` creates `v_concurrency_minute_title`, which does
`GROUP BY dictGet(..., 'title', ...)`. Its header comment analyses a *different* trap carefully — can
one session be open under two content_ids at once? (answer: no, `any(content_id)` collapses it
upstream, so summing deltas across content_id cannot double-count a viewer) — and that analysis is
sound. **It does not cover this case.** Title collision is not a double-count; it is a **merge of
distinct assets under one label**. The arithmetic is right; the name on it is ambiguous.

### (c) The planted poison row

```sql
SELECT * FROM csv_audit.content_str WHERE toInt64OrNull(content_id) < 0;
```

| content_id | title | video_type | category |
|---|---|---|---|
| **-987654322** | necec ceg | vod | cgdgn |

- Exactly **one** such row in 33,464.
- It has **zero events** in the raw file (`WHERE content_id = '-987654322'` → 0).
- In the *event* file: 0 negatives, min `20,971,538`, max `2,078,177,474`, all Int64-parseable.

We already type `content_id` as `Int64` everywhere for this reason (`DATA_DICTIONARY.md` trap 5). The
open part is not our schema — it is whether the unseen day plants one in the **event** stream, where it
would also break joins rather than merely sitting inert in a dimension.

---

## Exactly what to ask

> "Three things about the content file, all about how we should *label* content-level answers rather
> than how to compute them.
>
> **One — the empty `video_type`.** 1,089 of your 33,464 catalog rows have an empty string for
> `video_type`, and 25,810 events — 2.85% — land on them. So a breakdown by video type gets three
> buckets, not two. Should those be reported as a third category — we'd call it 'unknown' — or is the
> blank meaningful, or should those assets be excluded from video-type breakdowns entirely? We want to
> match however the answer key treats them, because a filter of `video_type IN ('vod','live')` silently
> drops 2.85% of events.
>
> **Two — title is not unique.** 2,773 of your titles are shared by two to four different
> `content_id`s, and 1,418 of those collisions cross *category* boundaries. When a benchmark query asks
> for concurrency 'by title' or 'by content', is the grouping key the **content_id**, or the **title
> string**? Those give different answers for 8.8% of your catalog, and we'd rather match your
> definition than pick one.
>
> **Three — the negative content_id.** You have exactly one catalog row with `content_id =
> -987654322`, and it has no events. We're treating that as a deliberate poison row and we've typed the
> column `Int64` everywhere so it round-trips. Will the unseen day carry the same trap — and could a
> negative content_id appear in the *event* stream rather than only in the catalog? Also: will every
> event's `content_id` still have a catalog row? Today there are zero orphans; if that changes, an
> inner join would silently delete those events and undercount concurrency, so we'd like to know
> whether to make the join defensive."

---

## Why this is worth mentor time

These do not change the concurrency **arithmetic** — they change what the numbers are **called**, and
the benchmark set is scored against a private key that has already made these choices. Getting the
grouping key wrong ("by title" vs "by content_id") produces a confidently wrong answer to a question we
answered correctly.

The orphan question is the one with teeth for the unseen day. Zero orphans today is luck, not a
contract; a fresh day with new or late catalog entries can reference ids absent from the catalog, and
an `INNER JOIN` would then delete those events **silently** — concurrency drops and nothing errors.

The cost of asking is low and the cost of guessing is a whole category of benchmark answers.

## How the answer changes what we build

| If they say | We change | Cost |
|---|---|---|
| **empty `video_type` is a third bucket** | relabel `''` → `'unknown'` in the three `_video_type` views; state it in the deck | one `if()` per view |
| **empty `video_type` should be excluded** | add `WHERE video_type != ''` to the video-type views only — never to the totals | one predicate |
| **group by `content_id`, show title as a decoration** | `v_concurrency_minute_title` is the wrong grain; promote `v_concurrency_minute_content` (already exists, already enriched) as the answer view | zero new code — the correct view is already built |
| **group by the `title` string** | keep `v_concurrency_minute_title`, and **document the merge** in its header so nobody reads it as per-asset | one comment |
| **unseen day may carry orphans** | keep `LEFT` semantics + `dictGet` default (already the design), and add an orphan-count assertion to `/reconcile` so a fresh day fails loudly instead of quietly | ~5 lines in `sql/90_reconcile.sql` |
| **negative ids may appear in events** | already covered — `Int64` end to end. Add one assertion at load that `min(content_id)` is Int64-parseable | ~2 lines in `tools/load.sh` |
| *no answer received* | ship both grains (`content_id` and `title`), label the blank explicitly as `unknown`, and say in the deck which one we treat as canonical and why | small; converts ambiguity into a stated choice |

## Our current assumption

Group by `content_id` is canonical; `title` / `category` / `video_type` are rollups on top. Empty
`video_type` is left as `''` (real source data, not a join failure). `content_id` is `Int64`
everywhere. The join stays `LEFT` with a `'(unknown)'` dictionary default so an orphan is visible
rather than dropped.

## Answer

**Recorded 2026-08-01, from a mentor conversation (verbal).** The mentor did not adjudicate the three
labelling sub-questions individually. The answer was broader and prescriptive:

> The solution should **handle erroneous data** — empty strings, nulls, duplication — and it should be
> handled **before joins and before any materialised view is built**: a data **pre-processing /
> validation stage**, not case-by-case patches inside the serving views.

### What that decides, mapped onto the decision table above

| Sub-question | Verdict implied by the answer |
|---|---|
| empty `video_type` | It is *erroneous data to be handled*, not meaningful blank. Relabel `''` → `'unknown'` **at the pre-processing stage** (i.e. in the cleaned dimension the dictionary loads from), not per-view. The 25,810 events (2.85%) stay counted, under an explicit bucket. |
| duplication | Pre-processing must dedup **before** the joins/MVs, even though we measured the 4,209 exact duplicates as inert to the interval model. "Proven inert" is no longer a sufficient answer — dedup is an expected, visible stage of the pipeline. |
| nulls / orphans | Handle defensively before the join: keep `LEFT` semantics + `'(unknown)'` dictGet default, and assert orphan-count at load so an unseen-day orphan fails loudly. Same posture for a negative `content_id` appearing in the *event* stream. |
| grouping key (`content_id` vs `title`) | **Not answered.** Still open — re-ask. `content_id` stays our canonical grain meanwhile. |

### What this obligates us to build (tracked in TODOS.md)

1. **A pre-processing stage between load and model** — either a cleaned landing table
   (`ev_clean` / `content_clean`) or a validated INSERT…SELECT — that (a) deduplicates exact replays,
   (b) normalises empty-string dimension values to an explicit `'unknown'` label
   (`audio_language` 1,991 · `subtitle_language` 2,006 · `player_version` 1,534 empty rows measured;
   catalog `video_type` 1,089), (c) quarantines rows failing hard validation (unparseable timestamp,
   empty `video_session_id`/`content_id` — today zero, unseen day unknown) into a visible reject
   table rather than dropping them.
2. **`dict_content` re-pointed at the cleaned dimension**, so the `''` → `'unknown'` relabel happens
   once, upstream of every view.
3. **Load-time assertions** promoted from "nice to have" to required: row-count vs source, orphan
   count, duplicate count, timestamp-parseability — each printed by `tools/load.sh` and failing loudly.
4. The dedup caveat stands: one duplicate group differs in `subtitle_language` (`UNK` vs `OFF`), so
   dedup must key on the full tuple *minus* volatile dimension columns, with a deterministic winner —
   not `DISTINCT *`.

**Caution:** pre-processing must not silently *change* graded answers. The cleaned tables feed the
model; `csv_audit` stays byte-faithful, and `/reconcile` must be re-run after the stage lands to prove
the interval arithmetic is unchanged (duplicates were measured inert, so the peak should not move; if
it moves, that is a finding, not a cleanup).
