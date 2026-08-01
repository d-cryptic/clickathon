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
#   tools/load.sh [--database NAME] [--replace|--append] [raw.csv] [content.csv]
#
#   tools/load.sh                             # REFUSES if the tables already hold rows
#   tools/load.sh --replace                   # TRUNCATE both tables first, announcing the loss
#   tools/load.sh --append                    # knowingly add to what is already there
#   CH_DATABASE=x TARGET=cloud tools/load.sh  # loads into x — the environment now wins
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
  sed -n '2,20p' "$0" >&2
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
RAW=""
CONTENT=""
NPOS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --database)   [ $# -ge 2 ] || die "--database needs a name"; ARG_DB="$2"; shift 2 ;;
    --database=*) ARG_DB="${1#--database=}"; shift ;;
    --replace)    MODE=replace; shift ;;
    --append)     MODE=append;  shift ;;
    -h|--help)    usage ;;
    --*)          die "unknown option: $1
usage: tools/load.sh [--database NAME] [--replace|--append] [raw.csv] [content.csv]" ;;
    *)            NPOS=$((NPOS + 1))
                  case $NPOS in
                    1) RAW="$1" ;;
                    2) CONTENT="$1" ;;
                    *) die "too many arguments (got '$1')
usage: tools/load.sh [--database NAME] [--replace|--append] [raw.csv] [content.csv]" ;;
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

echo "loading content_dim from $CONTENT ..."
run "INSERT INTO content_dim SELECT content_id, title, video_type, category FROM input('$CONTENT_COLS') FORMAT CSVWithNames" < "$CONTENT"

echo "loading ev_raw from $RAW ..."
run "INSERT INTO ev_raw SELECT content_id, video_session_id, user_id, event_type, event, toDateTime64(event_timestamp/1000, 3), platform, app_version, country, audio_language, subtitle_language, player_version, toDateTime64(session_start_epoch/1000, 3) FROM input('$RAW_COLS') FORMAT CSVWithNames" < "$RAW"

# Count through run(), not docker exec — a TARGET=cloud load has no local container,
# and reporting local counts after a Cloud load would be actively misleading.
# Report the DELTA as well as the total: a total alone cannot tell a clean load
# from a doubled one, which is the whole subject of the guard above.
echo "loaded into TARGET=$TARGET, database $DB:"
query "SELECT 'ev_raw' AS t, $RAW_BEFORE AS before, count() AS rows, count() - $RAW_BEFORE AS added FROM ev_raw
       UNION ALL
       SELECT 'content_dim', $CONTENT_BEFORE, count(), count() - $CONTENT_BEFORE FROM content_dim
       FORMAT PrettyCompact"
