#!/usr/bin/env bash
# tools/clickstack-cloud-sources.sh — register our concurrency sources in the
# HyperDX that is BUILT INTO ClickHouse Cloud, via the Cloud control-plane API.
#
# This is the hosted counterpart of clickstack-sources.sh (which drives the
# self-hosted all-in-one). Endpoints live under
#   /v1/organizations/{org}/services/{svc}/clickstack/{sources,dashboards,alerts,...}
# and authenticate with a Cloud API key over HTTP basic — NOT with the console
# session, so this is scriptable.
#
# THE ONE MANUAL PREREQUISITE: a source needs a `connection` id, and the API
# exposes no endpoint to list or create connections (verified: /clickstack/
# connections 404s; only sources/dashboards/alerts/roles/webhooks/saved-searches
# exist). The connection is provisioned when HyperDX is first opened in the
# console. So: open HyperDX once, then run this. It discovers the connection id
# from whatever source already exists and needs no further clicking, ever.
#
#   tools/clickstack-cloud-sources.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

: "${CH_API_KEY_ID:?set CH_API_KEY_ID in .env (Cloud console -> Settings -> API Keys)}"
: "${CH_API_KEY_SECRET:?set CH_API_KEY_SECRET in .env}"
DB="${CH_DATABASE:-sonyliv}"
API=https://api.clickhouse.cloud/v1

# NOTE: quote -u "$ID:$SECRET" at every call site. zsh does not word-split an
# unquoted "$AUTH" holding '-u id:secret', so it arrives as ONE argument and the
# API answers 401 "Key is not found" — which reads exactly like a bad key.
api() { curl -sS -u "$CH_API_KEY_ID:$CH_API_KEY_SECRET" "$@"; }

ORG=$(api "$API/organizations" | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(r[0]["id"] if r else "")')
[ -n "$ORG" ] || { echo "no organization returned — is the API key valid?" >&2; exit 1; }

# Match the service by the host in CH_HOST so a multi-service org picks the right one.
WANT_HOST="${CH_HOST#https://}"; WANT_HOST="${WANT_HOST%/}"; WANT_HOST="${WANT_HOST%%:*}"
SVC=$(api "$API/organizations/$ORG/services" | WANT="$WANT_HOST" python3 -c '
import json, os, sys
want = os.environ["WANT"]
svcs = json.load(sys.stdin)["result"]
for s in svcs:
    for e in (s.get("endpoints") or []):
        if e.get("host") == want:
            print(s["id"]); raise SystemExit
print(svcs[0]["id"] if svcs else "")
')
[ -n "$SVC" ] || { echo "no service matched $WANT_HOST" >&2; exit 1; }
echo "org $ORG · service $SVC"

BASE="$API/organizations/$ORG/services/$SVC/clickstack"
api "$BASE/sources" > /tmp/cs-sources.json

CONN=$(python3 -c '
import json
srcs = json.load(open("/tmp/cs-sources.json"))["result"]
print(next((s.get("connection","") for s in srcs if s.get("connection")), ""))
')

if [ -z "$CONN" ]; then
  cat >&2 <<'EOF'
No ClickStack connection exists on this service yet, and the Cloud API exposes no
way to create one (there is no /clickstack/connections endpoint).

Do this ONCE, then re-run this script:
  ClickHouse Cloud console -> HyperDX -> open it
Opening it provisions the default connection to this service. This script then
discovers the id automatically and creates every source over the API.
EOF
  exit 2
fi
echo "connection $CONN"

add_source() {  # add_source <name> <table> <select expression>
  local name="$1" table="$2" select="$3" existing
  existing=$(SRC_NAME="$name" python3 -c '
import json, os
srcs = json.load(open("/tmp/cs-sources.json"))["result"]
print(next((s.get("id","") for s in srcs if s.get("name") == os.environ["SRC_NAME"]), ""))
')
  if [ -n "$existing" ]; then echo "  source '$name' exists"; return; fi
  api -X POST "$BASE/sources" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$name\",\"kind\":\"log\",\"connection\":\"$CONN\",\"from\":{\"databaseName\":\"$DB\",\"tableName\":\"$table\"},\"timestampValueExpression\":\"minute\",\"defaultTableSelectExpression\":\"$select\"}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  created" if not d.get("error") else "  FAILED: "+d["error"])'
}

add_source "Concurrency total (minute)" v_concurrency_minute_total     "minute, concurrent"
add_source "Concurrency (minute)"       v_concurrency_minute_stateless "minute, platform, country, content_id, concurrent"

echo
echo "Open HyperDX and set the range to 2026-07-14 -> 2026-07-26."
echo "The dataset is NOT 'now'; the default last-15-minutes window renders empty."
