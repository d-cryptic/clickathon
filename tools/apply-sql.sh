#!/usr/bin/env bash
# tools/apply-sql.sh — apply sql/*.sql to local or Cloud.
#
# The compose mount at /docker-entrypoint-initdb.d runs ONLY on first boot of an
# empty data dir, and Cloud has no such mount at all. So there was no way to
# apply a schema change to a running server without hand-pasting DDL — which is
# how a Cloud service ends up subtly different from local.
#
# Multi-statement files go over the native protocol via clickhouse-client, since
# the HTTP endpoint rejects multi-statements.
#
#   tools/apply-sql.sh                            # every sql/*.sql to local
#   TARGET=cloud tools/apply-sql.sh               # every sql/*.sql to Cloud
#   TARGET=cloud tools/apply-sql.sh sql/20_views.sql
#   TARGET=cloud tools/apply-sql.sh --database sonyliv_scratch sql/00_schema.sql
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  sed -n '2,16p' "$0" >&2
  exit 2
}
die() { printf '\n=== apply-sql.sh FAILED ===\n%s\n\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# DATABASE RESOLUTION — bug 11, docs/SESSION-2026-08-01.md §4 / RUNBOOK A5
#
# Two separate faults lived here:
#   * `set -a && . ./.env` OVERWRITES a CH_DATABASE passed in the environment,
#     so `CH_DATABASE=scratch tools/apply-sql.sh` applied DDL to whatever .env
#     said — usually the graded database. The environment now wins; capture its
#     view BEFORE sourcing the file so the two can be told apart.
#   * the LOCAL branch never passed --database at all, so every local apply
#     landed in `default` no matter what the configuration said.
#
# Precedence — explicitness first, then specificity. No fallback on either
# target: guessing which database to apply DDL to is how a graded service ends
# up with tables nobody meant to create, and `default` is exactly where a
# mistargeted local apply used to land without a word.
#
#   TARGET=cloud   --database  >  $CH_DATABASE  >  .env CH_DATABASE  >  die
#   TARGET=local   --database  >  $CH_DATABASE_LOCAL  >  $CH_DATABASE
#                              >  .env CH_DATABASE_LOCAL  >  .env CH_DATABASE  >  die
#
# CH_DATABASE_LOCAL exists because the local container's data lives in `default`
# while CH_DATABASE names the Cloud database (see .env.example). Put
# `CH_DATABASE_LOCAL=default` in .env for local work.
# ---------------------------------------------------------------------------
ENV_DB="${CH_DATABASE-}"
ENV_DB_LOCAL="${CH_DATABASE_LOCAL-}"
[ -f .env ] && set -a && . ./.env && set +a
FILE_DB="${CH_DATABASE-}"
FILE_DB_LOCAL="${CH_DATABASE_LOCAL-}"

TARGET="${TARGET:-local}"
ARG_DB=""
FILES=()
NFILES=0   # counted rather than ${#FILES[@]}: an empty array under `set -u` is
           # an unbound-variable error on the bash 3.2 that ships with macOS.

while [ $# -gt 0 ]; do
  case "$1" in
    --database)   [ $# -ge 2 ] || die "--database needs a name"; ARG_DB="$2"; shift 2 ;;
    --database=*) ARG_DB="${1#--database=}"; shift ;;
    -h|--help)    usage ;;
    --*)          die "unknown option: $1
usage: tools/apply-sql.sh [--database NAME] [file...]" ;;
    *)            FILES+=("$1"); NFILES=$((NFILES + 1)); shift ;;
  esac
done

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

case "$DB" in
  *[!A-Za-z0-9_]* | "" | [0-9]*) die "not a usable database name: '$DB' (from $DB_SRC)" ;;
esac

CH_FLAG=""
if [ "$TARGET" = cloud ]; then CH_FLAG="-c "; fi

# The Cloud console hands you https://xxx.clickhouse.cloud; we add the scheme
# ourselves, so strip it. Same normalisation as tools/ch and tools/load.sh.
ch_host() { local h="${CH_HOST:?CH_HOST unset — fill in .env}"; h="${h#https://}"; h="${h#http://}"; echo "${h%/}"; }

# Files: whatever was passed, else every sql/*.sql in lexical order. 05_users.sh
# is a shell script, not SQL, so the glob correctly skips it.
if [ "$NFILES" -eq 0 ]; then
  FILES=(sql/*.sql)
fi

apply() {  # apply <file>
  local f="$1"
  if [ "$TARGET" = cloud ]; then
    # Native protocol on 9440 (not CH_PORT, which is the HTTPS port): the
    # client speaks native, and multi-statement needs the client.
    docker exec -i -e CLICKHOUSE_PASSWORD="$CH_PASSWORD" ch clickhouse-client \
      --host "$(ch_host)" --port 9440 --secure --user "$CH_USER" \
      --database "$DB" --multiquery < "$f"
  else
    # --database was missing here: every local apply landed in `default`.
    docker exec -i ch clickhouse-client --database "$DB" --multiquery < "$f"
  fi
}

# Does the target database exist? Asked WITHOUT connecting through it, because
# connecting to a database that does not exist is itself the error.
sysq1() {
  if [ "$TARGET" = cloud ]; then
    curl -sS --fail-with-body "https://$(ch_host):${CH_PORT}/?database=default" \
      --user "${CH_USER}:${CH_PASSWORD}" --data-binary "$1 FORMAT TSVRaw" | tr -d '\r\n'
  else
    docker exec -i ch clickhouse-client --query "$1 FORMAT TSVRaw" < /dev/null | tr -d '\r\n'
  fi
}

if [ "$TARGET" = cloud ]; then
  echo "applying to CLOUD: $(ch_host)/${DB}   (database from $DB_SRC)"
else
  echo "applying to LOCAL: docker exec ch, database ${DB}   (from $DB_SRC)"
fi

[ "$(sysq1 "SELECT count() FROM system.databases WHERE name = '$DB'")" = "1" ] || \
  die "database '$DB' does not exist on TARGET=$TARGET (resolved from $DB_SRC).
Nothing was applied. Create it, or point at one that exists:
  tools/ch ${CH_FLAG}'CREATE DATABASE $DB'
If you meant the local container's own data: it lives in 'default'. Put
CH_DATABASE_LOCAL=default in .env, or pass --database default."

for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "no such file: $f" >&2; exit 1; }
  printf '  %-24s ... ' "$f"
  if apply "$f"; then echo "ok"; else echo "FAILED"; exit 1; fi
done

echo "done."
