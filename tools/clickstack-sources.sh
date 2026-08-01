#!/usr/bin/env bash
# tools/clickstack-sources.sh — point the local ClickStack at OUR concurrency data.
#
# clickstack-bootstrap.sh gets you a team and an OTLP key; that covers ClickStack
# observing our pipeline. This script covers the other direction: making HyperDX
# chart the concurrency the problem statement asks us to visualise.
#
# It registers a ClickHouse *connection* to the graded Cloud service and two
# *sources* over the views in sql/20_views.sql. Idempotent — re-running updates
# nothing and creates no duplicates, so it is safe in a boot sequence.
#
# Why Cloud and not the local container: Cloud is the graded target and holds the
# schema that matches sql/. ClickStack itself still runs locally; only the data
# it reads is remote.
#
#   tools/clickstack-sources.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

: "${CS_EMAIL:?set CS_EMAIL in .env}"
: "${CS_PASSWORD:?set CS_PASSWORD in .env}"
: "${CH_HOST:?set CH_HOST in .env}"
: "${CH_PASSWORD:?set CH_PASSWORD in .env}"

BASE=http://localhost:8000
JAR=$(mktemp -t cs-cookies.XXXXXX)
trap 'rm -f "$JAR"' EXIT

ch_host() { local h="$CH_HOST"; h="${h#https://}"; h="${h#http://}"; echo "${h%/}"; }
CONN_NAME="SonyLIV Cloud"

curl -sf -o /dev/null "$BASE/health" || { echo "ClickStack is not up — run: make stack-up" >&2; exit 1; }

curl -sS -c "$JAR" -X POST "$BASE/login/password" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$CS_EMAIL\",\"password\":\"$CS_PASSWORD\"}" -o /dev/null \
  || { echo "login failed — run tools/clickstack-bootstrap.sh first" >&2; exit 1; }

# --- connection -------------------------------------------------------------
CONN_ID=$(curl -sS -b "$JAR" "$BASE/connections" | CONN_NAME="$CONN_NAME" python3 -c '
import json, os, sys
name = os.environ["CONN_NAME"]
for c in json.load(sys.stdin):
    if c.get("name") == name:
        print(c.get("id") or c.get("_id", "")); break
')

if [ -n "$CONN_ID" ]; then
  echo "connection '$CONN_NAME' exists ($CONN_ID)"
else
  CONN_ID=$(curl -sS -b "$JAR" -X POST "$BASE/connections" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$CONN_NAME\",\"host\":\"https://$(ch_host):${CH_PORT:-8443}\",\"username\":\"${CH_USER:-default}\",\"password\":\"${CH_PASSWORD}\"}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or d.get("_id",""))')
  [ -n "$CONN_ID" ] || { echo "failed to create connection" >&2; exit 1; }
  echo "created connection '$CONN_NAME' ($CONN_ID)"
fi

# --- sources ----------------------------------------------------------------
# kind=log is the generic table source in HyperDX; timestampValueExpression is
# what makes `minute` the time axis every chart draws against.
add_source() {  # add_source <display name> <table> <select expression>
  local name="$1" table="$2" select="$3"
  local existing
  existing=$(curl -sS -b "$JAR" "$BASE/sources" | SRC_NAME="$name" python3 -c '
import json, os, sys
name = os.environ["SRC_NAME"]
print(next((s.get("id") or s.get("_id","") for s in json.load(sys.stdin) if s.get("name") == name), ""))
')
  if [ -n "$existing" ]; then
    echo "source '$name' exists ($existing)"
    return
  fi
  curl -sS -b "$JAR" -X POST "$BASE/sources" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$name\",\"kind\":\"log\",\"connection\":\"$CONN_ID\",\"from\":{\"databaseName\":\"${CH_DATABASE:-sonyliv}\",\"tableName\":\"$table\"},\"timestampValueExpression\":\"minute\",\"defaultTableSelectExpression\":\"$select\"}" \
    -o /dev/null -w "created source '$name' (HTTP %{http_code})\n"
}

add_source "Concurrency (minute)"       v_concurrency_minute_stateless "minute, platform, country, content_id, concurrent"
add_source "Concurrency total (minute)" v_concurrency_minute_total     "minute, concurrent"

echo
echo "HyperDX UI: http://localhost:8080"
echo "  Search -> source 'Concurrency total (minute)' -> chart concurrent over minute"
# The single most common way to conclude "the charts are broken": HyperDX opens
# on a "last 15 minutes" window and the dataset ends 2026-07-26.
echo "  Set the time range to 2026-07-14 → 2026-07-26. The dataset is NOT 'now',"
echo "  and the default 'last 15 minutes' window renders an empty chart."
