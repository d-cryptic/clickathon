#!/usr/bin/env bash
# tools/load.sh — load the provided CSVs into ev_raw + content_dim.
#
# Streams the file over stdin rather than using file(). Two reasons:
#   1. file() only reads from user_files_path — a bind-mounted /data gives
#      Code: 291 DATABASE_ACCESS_DENIED.
#   2. The GRADED target is ClickHouse Cloud, where there is no local file at all.
#      stdin works identically against local and Cloud, so we load the unseen day
#      exactly the way we tested.
#
# event_timestamp / session_start_epoch are epoch MILLIS in the source.
#
#   tools/load.sh [--database NAME] [--replace|--append] [--allow-missing a,b] [raw.csv] [content.csv]
#
#   tools/load.sh                             # REFUSES if the tables already hold rows
#   tools/load.sh --replace                   # TRUNCATE both tables first, announcing the loss
#   tools/load.sh --append                    # knowingly add to what is already there
#   tools/load.sh --allow-missing app_version # load despite a MISSING known column (fills defaults)
#   CH_DATABASE=x TARGET=cloud tools/load.sh  # loads into x — the environment now wins
#
# HEADER SHAPE CHECK (ADR 0024) — the judges said new filter columns WILL appear.
# Before loading a row, the incoming header is diffed against the expected schema:
#   NEW columns      -> announced, carried into the `extra` Map column, queryable
#                       the same day as extra['<name>'] with no migration
#   MISSING columns  -> REFUSED unless each is named in --allow-missing (a missing
#                       column is a decision, not a silent ''). event_timestamp and
#                       video_session_id can never be defaulted — no interval exists
#                       without them.
#   REORDERED        -> safe, columns map by name; noted and loaded
# Measured before this existed: a new column loaded silently and was DISCARDED, a
# removed column silently became '' on every row. Both now announce themselves.
#
# ---------------------------------------------------------------------------
# WHY IT REFUSES BY DEFAULT — bug 8, docs/SESSION-2026-08-01.md §4
# ---------------------------------------------------------------------------
# INSERT appends. sql/00_schema.sql claims `non_replicated_deduplication_window
# = 1000` makes "a replayed batch idempotent — the unseen day may be re-loaded";
# that setting is for non-replicated MergeTree and Cloud runs SharedMergeTree.
# MEASURED on Cloud 26.2.1.525 (evidence/unseen-rehearsal.txt, RUNBOOK A4): the
# identical 30,097-row CSV loaded twice left ev_raw at 60,194 rows in two
# byte-identical parts. Nothing errored, and a doubled ev_raw produces a
# plausible-looking concurrency curve that is wrong everywhere.
#
# tools/unseen-run.sh worked around it by DROPping the whole database first —
# in that script, not here — so anyone calling this loader directly still
# doubled their data. The guard belongs in the loader.
#
# REFUSAL, not truncate-by-default, is the default: on the graded day the second
# run is usually "that looked wrong, redo it", which is one flag away, but a
# stray re-run must never be able to destroy a good load. Idempotency was not an
# option — insert dedup measurably does not fire on this engine.
# ---------------------------------------------------------------------------
set -euo pipefail

usage() {
  sed -n '2,31p' "$0" >&2
  exit 2
}
die() { printf '\n=== load.sh FAILED ===\n%s\n\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# DATABASE RESOLUTION — bug 11, docs/SESSION-2026-08-01.md §4 / RUNBOOK A5
#
# CH_DATABASE used to be read only AFTER `. ./.env`, and `set -a` makes the file
# OVERWRITE anything passed in the environment — so `CH_DATABASE=scratch
# tools/load.sh` loaded into whatever .env said, i.e. usually the graded
# database. Capture the environment's view BEFORE sourcing the file so the two
# can be told apart and ranked.
#
# Precedence — explicitness first, then specificity. There is no fallback on
# either target: guessing which database to write is how the graded state gets
# clobbered, and `default` is exactly the database a mistargeted local load used
# to land in without a word.
#
#   TARGET=cloud   --database  >  $CH_DATABASE  >  .env CH_DATABASE  >  die
#   TARGET=local   --database  >  $CH_DATABASE_LOCAL  >  $CH_DATABASE
#                              >  .env CH_DATABASE_LOCAL  >  .env CH_DATABASE  >  die
#
# CH_DATABASE_LOCAL exists because the local container's data lives in `default`
# while CH_DATABASE names the Cloud database (see .env.example). Put
# `CH_DATABASE_LOCAL=default` in .env for local work; without it a local run now
# resolves to the Cloud name, does not find it, and says so instead of quietly
# writing to `default`.
#
# This script deliberately does NOT cd to the repo root — tools/unseen-run.sh
# invokes it from a sandbox holding an overridden .env, and that still works.
# ---------------------------------------------------------------------------
ENV_DB="${CH_DATABASE-}"
ENV_DB_LOCAL="${CH_DATABASE_LOCAL-}"
[ -f .env ] && set -a && . ./.env && set +a
FILE_DB="${CH_DATABASE-}"
FILE_DB_LOCAL="${CH_DATABASE_LOCAL-}"

TARGET="${TARGET:-local}"          # TARGET=cloud tools/load.sh
ARG_DB=""
MODE=refuse                        # refuse | replace | append
ALLOW_MISSING=""                   # comma-separated known columns the operator lets default
RAW=""
CONTENT=""
NPOS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --database)        [ $# -ge 2 ] || die "--database needs a name"; ARG_DB="$2"; shift 2 ;;
    --database=*)      ARG_DB="${1#--database=}"; shift ;;
    --replace)         MODE=replace; shift ;;
    --append)          MODE=append;  shift ;;
    --allow-missing)   [ $# -ge 2 ] || die "--allow-missing needs a comma-separated column list"
                       ALLOW_MISSING="$2"; shift 2 ;;
    --allow-missing=*) ALLOW_MISSING="${1#--allow-missing=}"; shift ;;
    -h|--help)    usage ;;
    --*)          die "unknown option: $1
usage: tools/load.sh [--database NAME] [--replace|--append] [--allow-missing a,b] [raw.csv] [content.csv]" ;;
    *)            NPOS=$((NPOS + 1))
                  case $NPOS in
                    1) RAW="$1" ;;
                    2) CONTENT="$1" ;;
                    *) die "too many arguments (got '$1')
usage: tools/load.sh [--database NAME] [--replace|--append] [--allow-missing a,b] [raw.csv] [content.csv]" ;;
                  esac
                  shift ;;
  esac
done

RAW="${RAW:-data/ch-hackathon-raw-data.csv}"
CONTENT="${CONTENT:-data/ch-hackathon-content-data.csv}"

DB=""
DB_SRC=""
if [ -n "$ARG_DB" ]; then
  DB="$ARG_DB"; DB_SRC="--database"
elif [ "$TARGET" != cloud ] && [ -n "$ENV_DB_LOCAL" ]; then
  DB="$ENV_DB_LOCAL"; DB_SRC="CH_DATABASE_LOCAL (environment)"
elif [ -n "$ENV_DB" ]; then
  DB="$ENV_DB"; DB_SRC="CH_DATABASE (environment)"
elif [ "$TARGET" != cloud ] && [ -n "$FILE_DB_LOCAL" ]; then
  DB="$FILE_DB_LOCAL"; DB_SRC="CH_DATABASE_LOCAL (.env)"
elif [ -n "$FILE_DB" ]; then
  DB="$FILE_DB"; DB_SRC="CH_DATABASE (.env)"
else
  die "no database: CH_DATABASE is unset and no --database was given.
Refusing to guess. Set CH_DATABASE in .env, export it, or pass --database NAME.
For TARGET=local, CH_DATABASE_LOCAL wins if set — the local container's data
lives in 'default' while CH_DATABASE names the Cloud database."
fi

# A --database that contradicts an explicitly-exported CH_DATABASE is a mistake,
# not a preference: one of the two is not what the operator thinks it is.
ENV_DB_EFFECTIVE="$ENV_DB"; ENV_DB_NAME=CH_DATABASE
if [ "$TARGET" != cloud ] && [ -n "$ENV_DB_LOCAL" ]; then
  ENV_DB_EFFECTIVE="$ENV_DB_LOCAL"; ENV_DB_NAME=CH_DATABASE_LOCAL
fi
if [ -n "$ARG_DB" ] && [ -n "$ENV_DB_EFFECTIVE" ] && [ "$ARG_DB" != "$ENV_DB_EFFECTIVE" ]; then
  die "--database $ARG_DB contradicts $ENV_DB_NAME=$ENV_DB_EFFECTIVE in the environment.
Make them agree, or unset $ENV_DB_NAME for this invocation."
fi

# Every database name reaches ClickHouse by string concatenation below. Anything
# that is not a plain identifier is either a typo or an injection.
case "$DB" in
  *[!A-Za-z0-9_]* | "" | [0-9]*) die "not a usable database name: '$DB' (from $DB_SRC)" ;;
esac

# Precomputed so the error messages below can print a command that actually
# works, without nesting quotes inside them.
CH_FLAG=""
DB_FLAG=""
if [ "$TARGET" = cloud ]; then CH_FLAG="-c "; fi
if [ -n "$ARG_DB" ];      then DB_FLAG="--database $DB "; fi

RAW_COLS='content_id Int64, video_session_id String, user_id String, event_type String, event String, event_timestamp UInt64, platform String, app_version String, country String, audio_language String, subtitle_language String, player_version String, session_start_epoch UInt64'
CONTENT_COLS='content_id Int64, title String, video_type String, category String'

# ---------------------------------------------------------------------------
# HEADER SHAPE CHECK — ADR 0024. Diff the incoming header against the expected
# column set BEFORE loading a row, and build the load statement from what is
# actually there:
#   known columns  -> loaded exactly as before, mapped by name (reorder-safe)
#   NEW columns    -> announced, then carried into the `extra` Map column
#   MISSING        -> refused, unless the operator names each one in
#                     --allow-missing; then loaded as the type default, loudly
# Measured before this existed (both SILENT): a new column was discarded, a
# removed one became '' on every row. The exact judge scenario — "there will be
# more new columns for filtering" — was a shrug. Now it is an announcement.
#
# The analysis emits the three statement fragments the INSERT needs:
#   INPUT_STRUCTURE  every header column, known ones with their parse type,
#                    new ones as String — for input('…')
#   SELECT_EXPRS     the 13 known expressions (epoch millis -> DateTime64), plus
#                    map('new1', new1, …) when new columns exist
#   INSERT_COLS      the known target columns, plus `extra` when new ones exist
# With an unchanged header these reduce to exactly the pre-0024 statement; the
# 13-column path is proven byte-identical in evidence/schema-drift/.
# New column names must be plain identifiers ([A-Za-z_][A-Za-z0-9_]*): every
# name below reaches ClickHouse by string concatenation, so anything else is
# refused as a typo or an injection, same policy as $DB above.
# ---------------------------------------------------------------------------
analyse_header() {  # analyse_header <csv> <expected-cols-spec> <table> <outfile>
  python3 - "$1" "$2" "$3" "$ALLOW_MISSING" "$4" <<'PY'
import csv, re, sys

csv_path, spec, table, allow_csv, out_path = sys.argv[1:6]
allow_missing = {c for c in allow_csv.split(",") if c}

# epoch-millis columns are converted at load; everything else passes through
CONVERT = {
    "event_timestamp":     "toDateTime64(event_timestamp/1000, 3)",
    "session_start_epoch": "toDateTime64(session_start_epoch/1000, 3)",
}
# what an --allow-missing column loads as (the target column's type default)
MISSING_EXPR = {"session_start_epoch": "toDateTime64(0, 3)"}
# columns without which the model cannot function at all — no flag overrides
NEVER_DEFAULT = {
    "ev_raw":      {"event_timestamp", "video_session_id"},
    "content_dim": {"content_id"},
}[table]

known, types = [], {}
for part in spec.split(","):
    name, typ = part.strip().split(" ", 1)
    known.append(name)
    types[name] = typ

try:
    with open(csv_path, newline="") as f:
        header = next(csv.reader(f))
except StopIteration:
    print(f"REFUSING: {csv_path} is empty — no header row", file=sys.stderr)
    sys.exit(3)

err = lambda *a: print(*a, file=sys.stderr)

new = [c for c in header if c not in types]
missing = [c for c in known if c not in header]
present = [c for c in header if c in types]

problems = []
dupes = sorted({c for c in header if header.count(c) > 1})
if dupes:
    problems.append("duplicate header columns: " + ", ".join(dupes))
bad = [c for c in new if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", c)]
if bad:
    problems.append(
        "new column names that are not plain identifiers: "
        + ", ".join(repr(c) for c in bad)
        + " — refused on the same grounds as a malformed database name"
    )

hard = [c for c in missing if c in NEVER_DEFAULT]
unacked = [c for c in missing if c not in NEVER_DEFAULT and c not in allow_missing]
acked = [c for c in missing if c not in NEVER_DEFAULT and c in allow_missing]

err(f"header shape: {table} <- {csv_path}")
if not new and not missing:
    order = "in the expected order" if present == known else "REORDERED (safe — columns map by name)"
    err(f"  all {len(known)} expected columns present, {order}")
if new:
    err(f"  NEW columns ({len(new)}): {', '.join(new)}")
    err(f"    -> carried into the `extra` Map — queryable today as extra['{new[0]}']")
if missing:
    err(f"  MISSING columns ({len(missing)}): {', '.join(missing)}")
if new and missing:
    err("    -> a NEW column beside a MISSING one may be a RENAME: "
        + ", ".join(f"{m} -> {n}?" for m, n in zip(missing, new)))
    err("       if so, fix the header instead of loading both halves of the mistake")
for c in acked:
    err(f"  --allow-missing {c}: every row gets the type default "
        f"({MISSING_EXPR.get(c, repr('') if types[c] == 'String' else '0')}) — "
        f"this dimension is BLANK for the entire file")

if problems or hard or unacked:
    if hard:
        what = ("no interval can be derived without them" if table == "ev_raw"
                else "no row is joinable without it")
        err(f"  REFUSING: {', '.join(hard)} missing — {what}; no flag overrides this")
    if unacked:
        err("  REFUSING: a missing column is a decision, not a silent ''.")
        err("    Fix the file, or acknowledge each one explicitly:")
        err(f"      tools/load.sh --allow-missing {','.join(unacked)} ...")
    for p in problems:
        err(f"  REFUSING: {p}")
    sys.exit(3)

struct = ", ".join(f"{c} {types[c]}" if c in types else f"{c} String" for c in header)
exprs = []
for c in known:
    if c in header:
        exprs.append(CONVERT.get(c, c))
    else:
        exprs.append(MISSING_EXPR.get(c, f"defaultValueOfTypeName('{types[c]}')"))
cols = list(known)
if new:
    exprs.append("map(" + ", ".join(f"'{c}', {c}" for c in new) + ")")
    cols.append("extra")

with open(out_path, "w") as f:
    f.write("INPUT_STRUCTURE=" + struct + "\n")
    f.write("SELECT_EXPRS=" + ", ".join(exprs) + "\n")
    f.write("INSERT_COLS=" + ", ".join(cols) + "\n")
    f.write("NEW_COLS=" + " ".join(new) + "\n")
PY
}
shape_val() { sed -n "s/^$2=//p" "$1"; }

# The Cloud console shows the host as https://xxx.clickhouse.cloud, and that is what
# lands in .env. We add the scheme ourselves, so strip it — otherwise curl is handed
# https://https://... and dies with "Could not resolve host: https".
ch_host() { local h="${CH_HOST:?CH_HOST unset — fill in .env}"; h="${h#https://}"; h="${h#http://}"; echo "${h%/}"; }

run() {  # run <sql> ; CSV arrives on stdin. Runs INSIDE $DB.
  if [ "$TARGET" = cloud ]; then
    curl -sS --fail-with-body \
      "https://$(ch_host):${CH_PORT}/?database=${DB}&query=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$1")" \
      --user "${CH_USER}:${CH_PASSWORD}" --data-binary @-
  else
    # --database was missing here: the local path ignored CH_DATABASE entirely
    # and every local load landed in `default`, whatever the config said.
    docker exec -i ch clickhouse-client --database "$DB" --query "$1"
  fi
}

query() {  # query <sql> ; no stdin — used for the post-load row counts
  run "$1" < /dev/null
}

# sysq <sql> — server-level questions (does the database exist, TRUNCATE). Must
# NOT connect through $DB: connecting to a database that does not exist is an
# error, and "does it exist" is the question.
sysq() {
  if [ "$TARGET" = cloud ]; then
    curl -sS --fail-with-body \
      "https://$(ch_host):${CH_PORT}/?database=default&query=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$1")" \
      --user "${CH_USER}:${CH_PASSWORD}" --data-binary @- < /dev/null
  else
    docker exec -i ch clickhouse-client --query "$1" < /dev/null
  fi
}
sysq1() { sysq "$1 FORMAT TSVRaw" | tr -d '\r\n'; }

[ -f "$CONTENT" ] || { echo "missing $CONTENT"; exit 1; }
[ -f "$RAW" ]     || { echo "missing $RAW"; exit 1; }

echo "target=$TARGET  database=$DB  (from $DB_SRC)  mode=$MODE"

# Shape check first: a refusal here costs nothing and fires before any guard
# that talks to the server. Reports go to stderr, fragments to the temp files.
SHAPE_DIR="$(mktemp -d)"
trap 'rm -rf "$SHAPE_DIR"' EXIT
analyse_header "$RAW"     "$RAW_COLS"     ev_raw      "$SHAPE_DIR/raw"     || \
  die "header shape check refused $RAW — see the report above. Nothing was loaded."
analyse_header "$CONTENT" "$CONTENT_COLS" content_dim "$SHAPE_DIR/content" || \
  die "header shape check refused $CONTENT — see the report above. Nothing was loaded."
RAW_NEW="$(shape_val "$SHAPE_DIR/raw" NEW_COLS)"
CONTENT_NEW="$(shape_val "$SHAPE_DIR/content" NEW_COLS)"

# ---------------------------------------------------------------------------
# PRE-LOAD GUARD. Everything below runs before a single row is inserted.
# ---------------------------------------------------------------------------
[ "$(sysq1 "SELECT count() FROM system.databases WHERE name = '$DB'")" = "1" ] || \
  die "database '$DB' does not exist on TARGET=$TARGET (resolved from $DB_SRC).
Nothing was loaded. Create it, or point at one that exists:
  tools/ch ${CH_FLAG}'CREATE DATABASE $DB'
If you meant the local container's own data: it lives in 'default'. Put
CH_DATABASE_LOCAL=default in .env, or pass --database default."

for t in ev_raw content_dim; do
  [ "$(sysq1 "SELECT count() FROM system.tables WHERE database = '$DB' AND name = '$t'")" = "1" ] || \
    die "$DB.$t does not exist. Apply the schema BEFORE loading:
  TARGET=$TARGET tools/apply-sql.sh --database $DB sql/00_schema.sql sql/10_intervals.sql
Order is not optional — mv_stateless is the only populator of cc_minute_stateless
and there is no backfill, so a schema applied after the load leaves it empty."
done

# New columns need somewhere to land. A pre-ADR-0024 table has no `extra` —
# say exactly what one statement fixes it, rather than failing inside INSERT.
for t in ev_raw content_dim; do
  case "$t" in ev_raw) NEWC="$RAW_NEW" ;; *) NEWC="$CONTENT_NEW" ;; esac
  [ -z "$NEWC" ] && continue
  [ "$(sysq1 "SELECT count() FROM system.columns WHERE database = '$DB' AND table = '$t' AND name = 'extra'")" = "1" ] || \
    die "the incoming file carries new columns ($NEWC) but $DB.$t predates ADR 0024
and has no \`extra\` column to carry them. One statement adopts it, then re-run:
  tools/ch ${CH_FLAG}\"ALTER TABLE $DB.$t ADD COLUMN IF NOT EXISTS extra Map(LowCardinality(String), String)\"
Nothing was loaded."
done

RAW_BEFORE=$(sysq1     "SELECT count() FROM $DB.ev_raw")
CONTENT_BEFORE=$(sysq1 "SELECT count() FROM $DB.content_dim")

if [ "$RAW_BEFORE" != "0" ] || [ "$CONTENT_BEFORE" != "0" ]; then
  case "$MODE" in
    refuse)
      die "REFUSING TO LOAD: $DB already holds data and INSERT APPENDS.
  $DB.ev_raw       $RAW_BEFORE rows
  $DB.content_dim  $CONTENT_BEFORE rows

Loading on top of this DOUBLES ev_raw. There is no error and no dedup — the
identical CSV loaded twice measured 60,194 rows from 30,097 (Cloud 26.2.1.525,
evidence/unseen-rehearsal.txt). Every concurrency number doubles and the curve
still looks plausible. NOTHING HAS BEEN LOADED.

Pick one, on purpose:
  tools/load.sh --replace ${DB_FLAG}...   TRUNCATE both tables, then load (destroys the rows above)
  tools/load.sh --append  ${DB_FLAG}...   add to them knowingly (e.g. a second day-file)"
      ;;
    replace)
      # Queue Q36, from Codex audit 005. --replace TRUNCATEs ev_raw and
      # content_dim, and against the GRADED database that destroys the raw
      # events every answer is derived from. The graded-write guards added on
      # 2026-08-02 covered build-model.sh and apply-sql.sh's DROP/TRUNCATE and
      # never covered this path at all — so the most destructive operation in
      # the repo was also the least guarded.
      #
      # ev_raw is the one thing a rebuild cannot recover from: both prior
      # incidents were survivable *because* ev_raw was intact.
      #
      # Announcing the loss is not the same as requiring consent. This asks.
      readonly GRADED_DB=sonyliv
      if [ "$DB" = "$GRADED_DB" ] && [ "${REPLACE_GRADED:-}" != yes ]; then
        cat >&2 <<EOF

tools/load.sh: REFUSING to --replace the graded database '$GRADED_DB'.

  This TRUNCATEs $GRADED_DB.ev_raw ($RAW_BEFORE rows) and
  $GRADED_DB.content_dim ($CONTENT_BEFORE rows). ev_raw is the raw event stream
  every served answer is derived from, and unlike the model tiers it CANNOT be
  rebuilt — it can only be re-loaded from the CSV, if you still have it.

  Both graded-database incidents were recoverable precisely because ev_raw was
  untouched. This is the operation that would remove that safety net.

  If you genuinely intend to reload the graded raw data:
    REPLACE_GRADED=yes TARGET=cloud tools/load.sh --replace ...

  For anything else, target a scratch database:  --database <name>
EOF
        exit 1
      fi
      echo
      echo "############################################################"
      echo "# --replace: TRUNCATING $DB ON TARGET=$TARGET"
      echo "#   $DB.ev_raw       $RAW_BEFORE rows  ->  0   (DESTROYED)"
      echo "#   $DB.content_dim  $CONTENT_BEFORE rows  ->  0   (DESTROYED)"
      echo "############################################################"
      echo
      sysq "TRUNCATE TABLE $DB.ev_raw"      > /dev/null
      sysq "TRUNCATE TABLE $DB.content_dim" > /dev/null
      RAW_BEFORE=0
      CONTENT_BEFORE=0
      ;;
    append)
      echo
      echo "############################################################"
      echo "# --append: ADDING TO EXISTING DATA in $DB on TARGET=$TARGET"
      echo "#   $DB.ev_raw       starts at $RAW_BEFORE rows"
      echo "#   $DB.content_dim  starts at $CONTENT_BEFORE rows"
      echo "# If this file has been loaded before, the day is now counted twice."
      echo "############################################################"
      echo
      ;;
  esac
elif [ "$MODE" = replace ]; then
  echo "  --replace: both tables are already empty, nothing to truncate"
fi

# The three fragments come from analyse_header above. On an unchanged header
# they reduce to exactly the pre-0024 statements (proven byte-identical by
# checksum in evidence/schema-drift/); with new columns, `extra` rides along.
echo "loading content_dim from $CONTENT ..."
run "INSERT INTO content_dim ($(shape_val "$SHAPE_DIR/content" INSERT_COLS)) SELECT $(shape_val "$SHAPE_DIR/content" SELECT_EXPRS) FROM input('$(shape_val "$SHAPE_DIR/content" INPUT_STRUCTURE)') FORMAT CSVWithNames" < "$CONTENT"

echo "loading ev_raw from $RAW ..."
run "INSERT INTO ev_raw ($(shape_val "$SHAPE_DIR/raw" INSERT_COLS)) SELECT $(shape_val "$SHAPE_DIR/raw" SELECT_EXPRS) FROM input('$(shape_val "$SHAPE_DIR/raw" INPUT_STRUCTURE)') FORMAT CSVWithNames" < "$RAW"

# Count through run(), not docker exec — a TARGET=cloud load has no local container,
# and reporting local counts after a Cloud load would be actively misleading.
# Report the DELTA as well as the total: a total alone cannot tell a clean load
# from a doubled one, which is the whole subject of the guard above.
echo "loaded into TARGET=$TARGET, database $DB:"
query "SELECT 'ev_raw' AS t, $RAW_BEFORE AS before, count() AS rows, count() - $RAW_BEFORE AS added FROM ev_raw
       UNION ALL
       SELECT 'content_dim', $CONTENT_BEFORE, count(), count() - $CONTENT_BEFORE FROM content_dim
       FORMAT PrettyCompact"
