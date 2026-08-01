-- ============================================================================
-- 15_normalise.sql — canonicalise the FILTER DIMENSION VALUES, at query time.
--
-- ADR 0008 promoted app_version / audio_language / subtitle_language /
-- player_version to filter dimensions and kept their values RAW. The values are
-- dirty: `hin`, `HIN`, `hin-hindi` and `hin-Hindi` are all Hindi, so
-- `WHERE audio_language = 'hin'` answers 1,768 for peak Hindi concurrency when
-- the true answer is 2,180 — it silently drops 23.3%. This file fixes that
-- WITHOUT rewriting a single stored byte. See ADR 0011 for the measurements.
--
-- THE POLICY, in one line: storage stays raw, normalisation is a RULE applied on
-- read. Nothing here changes any concurrency number the pipeline reports.
--
-- Why not normalise in storage (measured, ADR 0011):
--   * The graded ground truth is PRIVATE and may itself be un-normalised. A raw
--     column can answer both questions; a rewritten column can answer only one.
--   * It buys nothing on the totals. The derivation reads dimensions as LABELS
--     only — `ts` drives run splitting, `dim_events` merely tags. Re-deriving
--     with the values normalised produces byte-identical output: 30,769
--     intervals, 1,949.3 counted watch hours, peak 2,887. Normalisation
--     provably cannot move an interval boundary.
--   * It costs nothing to defer. MEASURED on the 28,101-row serving layer:
--     `WHERE audio_language = 'hin'` and `WHERE norm_lang(audio_language) = 'hin'`
--     both read 28,101 rows / 137 KiB. The raw filter was never pruning either —
--     audio_language sits at sort-key position 7, which ADR 0008 already
--     conceded. Query-time normalisation is therefore FREE, not a trade.
--
-- Why a RULE and not a mapping table:
--   The unseen day may carry values none of us has seen. A rule handles any
--   input; a hard-coded map passes unknown values through untouched and looks
--   like it worked. Demonstration from this very file: the primary-subtag rule
--   folds `-soundhandler` (13 rows, an ffmpeg handler name that leaked into the
--   audio field) into the empty bucket as a pure side effect. Nobody would have
--   put that value in a mapping table.
--
-- Why sentinels are CLASSIFIED and not BUCKETED:
--   Folding unk/UNK/UND/und/'' into one 'unknown' string is irreversible and
--   destroys the UND-vs-UNK distinction. Worse, MEASURED: strengthening the
--   sentinel by normalising BEFORE the dominant-value vote moves 202 of 30,769
--   intervals off a real subtitle label (`OFF`, `ENG`) onto the sentinel `unk`,
--   because UNK+unk then vote together and outvote OFF. So the identity function
--   never buckets; `lang_class()` labels alongside it and the caller chooses.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- SECTION 1 — the rule, as pure functions.
--
-- SQL UDFs, not a dictionary and not a view, because the rule has to be usable
-- in three places that have nothing else in common: a serving view, an ad-hoc
-- dashboard query, and (should we ever want it) the derivation itself. A
-- dictionary would need a source table of mappings — state a fresh database
-- would not have, and a list the unseen day would fall off the end of.
--
-- CAVEAT, worth knowing before you run this: ClickHouse SQL UDFs are SERVER-
-- global, not per-database. Creating them here puts them in scope for every
-- database on the service. Names are prefixed `norm_` / `lang_` to keep that
-- blast radius legible. `CREATE OR REPLACE` makes the file idempotent and safe
-- to re-run, which is the repo's contract for every file in sql/.
--
-- They are macros, so a UDF calling another UDF re-evaluates it. `norm_lang`
-- expands `norm_case` three times. At 28,101 rows that is unmeasurable; at
-- 1,000x it would be worth inlining. Recorded so nobody has to rediscover it.
-- ---------------------------------------------------------------------------

-- Step one, and the only step that applies to EVERY dimension: trim and fold
-- case. MEASURED, this merges nothing at all on four of the six dimensions —
-- platform 10 -> 10, player_version 14 -> 14, app_version 65 -> 65, country
-- 1 -> 1. It ships on them anyway as a defensive no-op: `Mweb` is the only
-- mixed-case platform and `india` the only country, so a `platform = 'MWEB'` or
-- `country = 'INDIA'` filter returns zero rows today and nobody would notice.
-- On the unseen day a case twin costs nothing to have already handled.
CREATE OR REPLACE FUNCTION norm_case AS (s) -> lower(trimBoth(toString(s)));

-- Step two, LANGUAGE COLUMNS ONLY: keep the primary subtag — everything before
-- the first hyphen. This is the BCP-47 shape (`hin-hindi`, `eng-English`,
-- `jpn-japanese`), so the rule is the standard one, not one invented for this
-- file. MEASURED collapse on the provided data:
--
--     audio_language     41 raw -> 26 case-folded -> 18 groups
--     subtitle_language  11 raw ->  8 case-folded ->  7 groups
--
-- The empty string maps to the empty string; `-soundhandler` maps to the empty
-- string too, because its primary subtag is empty. Both then classify as
-- `unknown` below, which is correct for both and was designed for neither.
--
-- DO NOT apply this to a version column. `norm_lang('v-0.0.117.12.05.1_adNE')`
-- returns `v`. Version columns get `norm_version` / `norm_app_version` instead,
-- and the separation is the reason there is no single `norm_dim()`.
CREATE OR REPLACE FUNCTION norm_lang AS (s) ->
    if(position(norm_case(s), '-') > 0,
       substring(norm_case(s), 1, position(norm_case(s), '-') - 1),
       norm_case(s));

-- Version columns: case-fold only. MEASURED: zero merges on player_version.
-- The `_ADE`/`_adE` and `_ADNE`/`_adNE` pairs that look like case twins are NOT
-- twins — `3.33.50_ADE` and `3.29.71_adE` are different releases, and the case
-- of the suffix tracks the version family (numeric >=3.32 upper, 3.29.71 lower,
-- `v-0.0.*` lower). No two player_version values collide under lower(). This is
-- a no-op today and a guard tomorrow.
CREATE OR REPLACE FUNCTION norm_version AS (s) -> norm_case(s);

-- app_version additionally drops zero-only components BEYOND the third, which
-- is what makes `5.0.36.00` and `5.0.36` one release. MEASURED, that is the
-- ONLY pair the rule touches across all 65 values: 65 distinct in, 64 out, one
-- rename, and the rename IS the merge. Both sides are the same player build
-- (`v-0.0.117.12.05.1_adNE`) on the same platform family (LG/Samsung HTML TV),
-- 13 sessions plus 5, 872 rows.
--
-- The `major.minor.patch` anchor is not decoration. The obvious rule — strip
-- any trailing `.0` — was written first and MEASURED: it renames four values to
-- buy the same one merge, turning `9.0.0` into `9` and `8.9.0` into `8.9`, which
-- then sits in a dropdown next to a real `8.9.1` and `8.9.2`. Three cosmetic
-- relabels for one true merge is a bad trade, so the rule is anchored to keep
-- the first three components intact and only collapse zero padding past them.
--
-- It is still the weakest rule in this file, and deliberately the narrowest: it
-- cannot merge `6.34.4` with `6.34`, only a version with its own zero-padded
-- self. All 65 values are digits-and-dots (verified: zero values match
-- `[^0-9.]`), so the regex cannot mangle a suffixed build id here.
CREATE OR REPLACE FUNCTION norm_app_version AS (s) ->
    replaceRegexpOne(norm_case(s), '^([0-9]+\.[0-9]+\.[0-9]+)(\.0+)+$', '\1');

-- ---------------------------------------------------------------------------
-- SECTION 2 — the classifier. Labels a value; never replaces it.
--
-- This is the ONE function here that carries a value list, and that is
-- deliberate: it decides how a value is DESCRIBED, never what it IS. The
-- default is `named`, so a sentinel we have never seen shows up as a bogus
-- language in a breakdown — visible and wrong — rather than being silently
-- swallowed into `unknown`. Failing loud beats failing tidy on the unseen day.
--
-- MEASURED distribution over 905,558 raw events:
--   subtitle_language  unknown 828,992 (91.5%) · off 45,496 · named 31,070
--                      of which `aut` 653 -> `auto`
--   audio_language     named 843,995 · unknown 53,189 · off 8,633
--
-- `non`/`NON` are classed `off`, not `unknown`: "no track selected" is a state
-- the viewer chose, distinct from "the player never told us". ISO 639-3 assigns
-- `non` to Old Norse; treating 8,633 SonyLIV rows as Old Norse is the sillier
-- of the two readings. `aut` is read as "auto-select", not as a language — no
-- ISO 639 code `aut` exists. Both are judgement calls, flagged in ADR 0011 and
-- in doubts/04.
CREATE OR REPLACE FUNCTION lang_class AS (s) ->
    multiIf(
        norm_lang(s) IN ('', 'unk', 'und', 'nil', 'null', 'na', 'n/a', 'undefined', 'unknown'), 'unknown',
        norm_lang(s) IN ('off', 'non', 'none', 'disabled'),                                     'off',
        norm_lang(s) IN ('aut', 'auto'),                                                        'auto',
        'named');

-- ---------------------------------------------------------------------------
-- SECTION 3 — self-test. Runs on LITERALS, so it needs no tables and no data.
--
-- This is what makes the file safe to apply to a fresh database: every
-- assertion below is a pure function call, so `15_normalise.sql` proves the
-- rule behaves before any view built on it is created. A regression in a UDF
-- fails HERE, loudly, at apply time — not three hours later as a wrong number
-- on a dashboard. throwIf raises Code: 395 and aborts the file.
-- ---------------------------------------------------------------------------
SELECT throwIf(norm_lang('hin')          != 'hin', 'norm_lang: identity broken')
     , throwIf(norm_lang('HIN')          != 'hin', 'norm_lang: case fold broken')
     , throwIf(norm_lang('hin-hindi')    != 'hin', 'norm_lang: long form broken')
     , throwIf(norm_lang('hin-Hindi')    != 'hin', 'norm_lang: mixed-case long form broken')
     , throwIf(norm_lang('  ENG  ')      != 'eng', 'norm_lang: trim broken')
     , throwIf(norm_lang('-soundhandler')!= '',    'norm_lang: leading hyphen broken')
     , throwIf(norm_lang('')             != '',    'norm_lang: empty broken')
     -- jap/jpn are BOTH Japanese and the rule deliberately does NOT merge them.
     -- Only a hard-coded synonym map could, and that is the thing this file
     -- refuses to be. Asserted so the limitation is a decision, not a bug.
     , throwIf(norm_lang('jap') = norm_lang('jpn'), 'norm_lang: must NOT merge jap/jpn — see ADR 0011')
     -- The subtag rule must never touch a version string.
     , throwIf(norm_version('3.33.50_ADE') != '3.33.50_ade', 'norm_version: case fold broken')
     , throwIf(norm_version('v-0.0.117.12.05.1_adNE') != 'v-0.0.117.12.05.1_adne',
               'norm_version: must not strip a subtag from a version')
     , throwIf(norm_app_version('5.0.36.00') != '5.0.36', 'norm_app_version: trailing zeros broken')
     , throwIf(norm_app_version('5.0.36')    != '5.0.36', 'norm_app_version: idempotence broken')
     , throwIf(norm_app_version('6.34.4')    != '6.34.4', 'norm_app_version: over-eager strip')
     -- The three-component anchor. These must NOT be renamed: `9.0.0` staying
     -- `9.0.0` and `8.9.0` staying `8.9.0` is the whole reason for the anchor.
     , throwIf(norm_app_version('9.0.0')     != '9.0.0',  'norm_app_version: anchor lost — 9.0.0 must not fold')
     , throwIf(norm_app_version('8.9.0')     != '8.9.0',  'norm_app_version: anchor lost — 8.9.0 must not fold')
     , throwIf(norm_app_version('8.8.0')     != '8.8.0',  'norm_app_version: anchor lost — 8.8.0 must not fold')
     , throwIf(lang_class('UNK')  != 'unknown', 'lang_class: sentinel broken')
     , throwIf(lang_class('und')  != 'unknown', 'lang_class: sentinel broken')
     , throwIf(lang_class('')     != 'unknown', 'lang_class: empty broken')
     , throwIf(lang_class('OFF')  != 'off',     'lang_class: off broken')
     , throwIf(lang_class('NON')  != 'off',     'lang_class: none broken')
     , throwIf(lang_class('AUT')  != 'auto',    'lang_class: auto broken')
     , throwIf(lang_class('hin')  != 'named',   'lang_class: named broken')
     -- An unseen sentinel must default to `named` — visible, not swallowed.
     , throwIf(lang_class('zzq')  != 'named',   'lang_class: unseen value must default to named')
     AS normalisation_self_test_passed;

-- ---------------------------------------------------------------------------
-- SECTION 4 — the serving view. Raw and normalised, side by side.
--
-- Every raw column is kept under its own name, so anything written against
-- cc_minute_delta reads identically through this view. The normalised values
-- arrive as ADDITIONAL `*_norm` columns plus the two class labels. That is the
-- whole answer to "what if the ground truth is un-normalised": both answers are
-- available from one view, and choosing between them is a WHERE clause rather
-- than a rebuild.
--
-- delta/starts/ends pass through untouched — normalisation is a relabelling, so
-- the running sum over this view equals the running sum over the base table for
-- any query that does not filter on a dimension. VERIFIED: peak 2,887 either
-- way.
--
-- Remember CONVENTIONS.md — a running sum over these deltas MUST
-- `PARTITION BY toStartOfHour(minute)`; they are hour-clipped per ADR 0003.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_cc_minute_delta_norm AS
SELECT
    minute,
    platform,
    country,
    content_id,
    subtitle_language,
    player_version,
    audio_language,
    app_version,
    norm_case(platform)              AS platform_norm,
    norm_case(country)               AS country_norm,
    norm_lang(audio_language)        AS audio_language_norm,
    norm_lang(subtitle_language)     AS subtitle_language_norm,
    norm_version(player_version)     AS player_version_norm,
    norm_app_version(app_version)    AS app_version_norm,
    lang_class(audio_language)       AS audio_class,
    lang_class(subtitle_language)    AS subtitle_class,
    delta,
    starts,
    ends
FROM cc_minute_delta;

-- Concurrency per minute per NORMALISED audio language, ready to chart.
-- The `WITH FILL` densification stays the caller's job (CONVENTIONS.md) — a
-- delta view emits a row only where concurrency changes, and densifying here
-- would defeat the delta model.
CREATE OR REPLACE VIEW v_concurrency_minute_audio_norm AS
SELECT
    minute,
    audio_language_norm,
    audio_class,
    sum(sum(delta)) OVER (
        PARTITION BY toStartOfHour(minute), audio_language_norm
        ORDER BY minute
    ) AS concurrent
FROM v_cc_minute_delta_norm
GROUP BY minute, audio_language_norm, audio_class;

-- ---------------------------------------------------------------------------
-- SECTION 5 — the drift audit. Point this at the unseen day BEFORE trusting a
-- filtered number from it.
--
-- The rule is fixed; the data is not. This view lists every normalisation group
-- that has more than one raw spelling, so a new family on the unseen day is
-- SEEN rather than assumed absent. It is also the evidence table behind ADR
-- 0011 — run it and the Hindi row prints itself.
--
-- Reads ev_raw, not the serving layer, deliberately: the point is to catch a
-- value before the derivation has voted on it and possibly discarded it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dimension_drift AS
SELECT dimension, normalised, class, variants, raw_values, rows
FROM
(
    SELECT 'audio_language' AS dimension, norm_lang(audio_language) AS normalised,
           lang_class(audio_language) AS class,
           uniqExact(audio_language) AS variants,
           arraySort(groupUniqArray(audio_language)) AS raw_values, count() AS rows
    FROM ev_raw GROUP BY normalised, class

    UNION ALL
    SELECT 'subtitle_language', norm_lang(subtitle_language), lang_class(subtitle_language),
           uniqExact(subtitle_language), arraySort(groupUniqArray(subtitle_language)), count()
    FROM ev_raw GROUP BY 2, 3

    UNION ALL
    SELECT 'player_version', norm_version(player_version), 'n/a',
           uniqExact(player_version), arraySort(groupUniqArray(player_version)), count()
    FROM ev_raw GROUP BY 2

    UNION ALL
    SELECT 'app_version', norm_app_version(app_version), 'n/a',
           uniqExact(app_version), arraySort(groupUniqArray(app_version)), count()
    FROM ev_raw GROUP BY 2

    UNION ALL
    SELECT 'platform', norm_case(platform), 'n/a',
           uniqExact(platform), arraySort(groupUniqArray(platform)), count()
    FROM ev_raw GROUP BY 2

    UNION ALL
    SELECT 'country', norm_case(country), 'n/a',
           uniqExact(country), arraySort(groupUniqArray(country)), count()
    FROM ev_raw GROUP BY 2
)
WHERE variants > 1
ORDER BY rows DESC;

-- The one-line version for the unseen-day runbook: how much would a naive
-- equality filter miss on each dimension? Anything above zero is a dimension
-- where `WHERE col = 'x'` is lying by that many rows.
CREATE OR REPLACE VIEW v_dimension_drift_summary AS
SELECT dimension,
       count()          AS groups_with_variants,
       sum(variants)    AS raw_values_involved,
       sum(rows)        AS rows_in_split_groups
FROM v_dimension_drift
GROUP BY dimension
ORDER BY rows_in_split_groups DESC;
