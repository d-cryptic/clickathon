#!/usr/bin/env bash
# 00-setup.sh — two scratch databases, same data, two serving designs.
#
#   gp_ctl   TODAY's design: four tier tables, built by tools/build-model.sh
#   gp_pin   ADR 0034: generation-keyed tiers + pinned base views + a pointer
#
# Both are loaded from the LOCAL `default` database's ev_raw (the delivered
# file). The graded Cloud database is never touched by anything in this
# directory — the guard below refuses to run if any script here names a write
# against it.
set -euo pipefail
cd "$(dirname "$0")/../.."

grep -nE '(INSERT|TRUNCATE|ALTER|CREATE|DROP|OPTIMIZE)[^;]*sonyliv[^_]' evidence/generation-pinning/*.sh \
  && { echo "refusing: a script here writes the graded database" >&2; exit 1; } || true

SRC="${SRC:-default}"
CTL=gp_ctl
PIN=gp_pin

# `env -u CH_DATABASE`: that variable names the GRADED database and is exported
# in any shell that sourced .env. Locally it must not resolve at all.
ch() { env -u CH_DATABASE CH_DATABASE_LOCAL="$1" tools/ch "$2"; }
apply() { env -u CH_DATABASE TARGET=local CH_DATABASE_LOCAL="$1" tools/apply-sql.sh --database "$1" "${@:2}" >/dev/null; }

# The files a serving database needs. 30/40 are the derivation INSERTs and are
# applied by tools/build-model.sh, not here; 70 builds its own database and is
# excluded on purpose.
SCHEMA=(sql/00_schema.sql sql/01_policy.sql sql/10_intervals.sql sql/15_normalise.sql sql/20_views.sql
        sql/45_user_concurrency.sql sql/50_hour_agg.sql sql/60_projection.sql
        sql/80_content.sql sql/85_windows.sql sql/87_viz.sql)

for db in "$CTL" "$PIN"; do
  echo "== $db"
  ch default "DROP DATABASE IF EXISTS $db" >/dev/null
  ch default "CREATE DATABASE $db" >/dev/null
  apply "$db" "${SCHEMA[@]}"
  ch "$db" "INSERT INTO ev_raw SELECT * FROM ${SRC}.ev_raw" >/dev/null
  ch "$db" "INSERT INTO content_dim SELECT * FROM ${SRC}.content_dim" >/dev/null
  echo "   ev_raw $(ch "$db" "SELECT count() FROM ev_raw FORMAT TSVRaw"), content_dim $(ch "$db" "SELECT count() FROM content_dim FORMAT TSVRaw")"
done

echo
echo "== $CTL — build the model the way it is built today"
TARGET=local CH_DATABASE_LOCAL="$CTL" tools/build-model.sh

echo
echo "== $PIN — install the generation-pinned surface, then build generation 1"
tools/generation-install.sh --database "$PIN"
TARGET=local tools/build-generation.sh --database "$PIN"

echo
echo "== both databases now serve the same answer"
for db in "$CTL" "$PIN"; do
  printf '   %-8s peak %s  delta rows %s\n' "$db" \
    "$(ch "$db" "SELECT max(concurrent) FROM v_concurrency_minute_delta_total FORMAT TSVRaw")" \
    "$(ch "$db" "SELECT count() FROM cc_minute_delta FORMAT TSVRaw")"
done
