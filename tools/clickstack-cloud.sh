#!/usr/bin/env bash
# tools/clickstack-cloud.sh — provision the HyperDX built into ClickHouse Cloud:
# sources, the demo dashboard, and saved searches. Idempotent.
#
# Drives the Cloud control-plane API, NOT the console session, so all of this is
# scriptable and survives a rebuild:
#   /v1/organizations/{org}/services/{svc}/clickstack/{sources,dashboards,saved-searches}
# Auth is HTTP basic with a Cloud API key (CH_API_KEY_ID / CH_API_KEY_SECRET).
#
# THE ONE MANUAL PREREQUISITE: everything here needs a `connection` id, and the
# API exposes no way to list or create one — verified, /clickstack/connections
# 404s on both GET and POST, and no ClickStackConnection schema exists in the
# OpenAPI spec. The connection is provisioned when HyperDX is first opened in
# the console. Open it once; this script discovers the id and never needs
# clicking again, including for the unseen-day rebuild.
#
#   tools/clickstack-cloud.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

: "${CH_API_KEY_ID:?set CH_API_KEY_ID in .env (Cloud console -> Settings -> API Keys)}"
: "${CH_API_KEY_SECRET:?set CH_API_KEY_SECRET in .env}"
DB="${CH_DATABASE:-sonyliv}"
API=https://api.clickhouse.cloud/v1

# NOTE: quote -u "$ID:$SECRET" at every call site. zsh does NOT word-split an
# unquoted variable holding '-u id:secret', so it reaches curl as one argument
# and the API answers 401 "Key is not found" — indistinguishable from a bad key.
api() { curl -sS -u "$CH_API_KEY_ID:$CH_API_KEY_SECRET" "$@"; }
py() { python3 -c "$1"; }

ORG=$(api "$API/organizations" | py 'import json,sys; r=json.load(sys.stdin)["result"]; print(r[0]["id"] if r else "")')
[ -n "$ORG" ] || { echo "no organization returned — is the API key valid?" >&2; exit 1; }

# Match the service by CH_HOST so a multi-service org cannot pick the wrong one.
WANT_HOST="${CH_HOST#https://}"; WANT_HOST="${WANT_HOST%/}"; WANT_HOST="${WANT_HOST%%:*}"
SVC=$(api "$API/organizations/$ORG/services" | WANT="$WANT_HOST" py '
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
BASE="$API/organizations/$ORG/services/$SVC/clickstack"
echo "org $ORG · service $SVC"

refresh_sources() { api "$BASE/sources" > /tmp/cs-sources.json; }
refresh_sources

# Connection discovery is a chicken-and-egg: the REST API returns connections
# ONLY nested inside sources, and has no /clickstack/connections endpoint (404s
# on GET and POST). So on a service with zero sources there is nothing to read
# it from — which is exactly the state a fresh service is in.
# Prefer the explicit id from .env; fall back to reading it off any source.
CONN="${CLICKSTACK_CONNECTION_ID:-}"
if [ -z "$CONN" ]; then
  CONN=$(py '
import json
print(next((s.get("connection","") for s in json.load(open("/tmp/cs-sources.json"))["result"] if s.get("connection")), ""))
')
fi

if [ -z "$CONN" ]; then
  cat >&2 <<'EOF'
No ClickStack connection id available.

The Cloud REST API cannot supply one on a service with no sources: connections
are only ever returned nested inside a source, and /clickstack/connections 404s
on GET and POST.

Get it once, then put it in .env as CLICKSTACK_CONNECTION_ID:
  - the clickstack MCP: clickstack_list_sources returns a top-level
    `connections` array even when `sources` is empty, or
  - open HyperDX in the console once, which provisions and reveals it.
EOF
  exit 2
fi
echo "connection $CONN"

# ---------------------------------------------------------------- sources ----
add_source() {  # add_source <name> <table> <select expression>
  local name="$1" table="$2" select="$3" existing
  existing=$(SRC_NAME="$name" py '
import json, os
print(next((s.get("id","") for s in json.load(open("/tmp/cs-sources.json"))["result"] if s.get("name") == os.environ["SRC_NAME"]), ""))
')
  if [ -n "$existing" ]; then echo "  source '$name' exists"; return; fi
  api -X POST "$BASE/sources" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$name\",\"kind\":\"log\",\"connection\":\"$CONN\",\"from\":{\"databaseName\":\"$DB\",\"tableName\":\"$table\"},\"timestampValueExpression\":\"minute\",\"defaultTableSelectExpression\":\"$select\"}" \
    | py 'import json,sys; d=json.load(sys.stdin); print("  created" if not d.get("error") else "  FAILED: "+d["error"]); sys.exit(1 if d.get("error") else 0)'
}

echo "sources:"
# The ACCURATE pair (gap+pause model, ADR 0007) and the STATELESS baseline.
# Both are charted: the statement asks for the comparison explicitly.
add_source "Concurrency ACCURATE (minute)"      v_concurrency_minute_delta_total   "minute, concurrent"
add_source "Concurrency ACCURATE by dimension"  v_concurrency_minute               "minute, platform, country, content_id, concurrent"
add_source "Concurrency total (minute)"         v_concurrency_minute_total         "minute, concurrent"
add_source "Concurrency (minute)"               v_concurrency_minute_stateless     "minute, platform, country, content_id, concurrent"
refresh_sources

src_id() { SRC_NAME="$1" py '
import json, os
print(next((s.get("id","") for s in json.load(open("/tmp/cs-sources.json"))["result"] if s.get("name") == os.environ["SRC_NAME"]), ""))
'; }
ACC_ID=$(src_id "Concurrency ACCURATE (minute)")
ACC_DIM_ID=$(src_id "Concurrency ACCURATE by dimension")
TOTAL_ID=$(src_id "Concurrency total (minute)")
DIM_ID=$(src_id "Concurrency (minute)")
for v in ACC_ID ACC_DIM_ID TOTAL_ID DIM_ID; do
  eval "[ -n \"\$$v\" ]" || { echo "source id $v missing after create" >&2; exit 1; }
done

# -------------------------------------------------------------- dashboard ----
# Built from the real schemas: ClickStackCreateDashboardRequest requires
# {name,tiles}; each ClickStackTileInput requires {name,x,y,w,h}; a line tile's
# ClickStackLineBuilderChartConfig requires {displayType,sourceId,select}.
DASH_NAME="SonyLIV concurrency"
DASH_JSON=$(ACC_ID="$ACC_ID" ACC_DIM_ID="$ACC_DIM_ID" TOTAL_ID="$TOTAL_ID" DIM_ID="$DIM_ID" DASH_NAME="$DASH_NAME" py '
import json, os
acc, accdim = os.environ["ACC_ID"], os.environ["ACC_DIM_ID"]
total, dim    = os.environ["TOTAL_ID"], os.environ["DIM_ID"]
name          = os.environ["DASH_NAME"]

def line(n, src, x, y, w, h, group=None, alias="concurrent"):
    cfg = {"displayType": "line", "sourceId": src,
           "select": [{"aggFn": "max", "valueExpression": "concurrent", "alias": alias}],
           "where": "", "whereLanguage": "sql"}
    if group:
        cfg["groupBy"] = group
    return {"name": n, "x": x, "y": y, "w": w, "h": h, "config": cfg}

# Dashboard-level filters. type QUERY_EXPRESSION with appliesToSourceIds so one
# control drives every tile that carries the dimension. The two total-only
# sources have no dimension columns, so they are deliberately NOT listed —
# naming them would make the filter error rather than no-op.
def filt(label, column):
    return {"type": "QUERY_EXPRESSION", "name": label, "expression": column,
            "sourceId": accdim, "appliesToSourceIds": [accdim, dim]}

print(json.dumps({
  "name": name,
  "tags": ["clickathon"],
  "filters": [filt("Platform", "platform"),
              filt("Country", "country"),
              filt("Content", "content_id")],
  "tiles": [
    # The headline: the real model, foreground-only.
    line("Concurrency — ACCURATE (gap + pause excluded)", acc, 0, 0, 12, 4, alias="accurate"),
    # The comparison the statement asks for, side by side underneath.
    line("Baseline — stateless (no session reconstruction)", total, 0, 4, 6, 4, alias="stateless"),
    line("ACCURATE by platform", accdim, 6, 4, 6, 4, "platform"),
    line("ACCURATE by content",  accdim, 0, 8, 6, 4, "content_id"),
    line("ACCURATE by country",  accdim, 6, 8, 6, 4, "country"),
  ]}))
')

# PUT validates against ClickStackFilter (id REQUIRED); validate and POST use
# ClickStackFilterInput (id FORBIDDEN — it rejects the key outright). Same
# dashboard, two shapes. Stable ids derived from the label so a re-run updates
# the same filter instead of duplicating it.
DASH_JSON_PUT=$(DASH="$DASH_JSON" py '
import hashlib, json, os
d = json.loads(os.environ["DASH"])
for f in d.get("filters", []):
    f["id"] = hashlib.md5(("sonyliv-filter-" + f["name"]).encode()).hexdigest()[:24]
print(json.dumps(d))
')

echo "dashboard:"
# Validate before creating. The API offers /dashboards/validate precisely so a
# malformed tile fails here with a path, not as a blank panel in front of judges.
VALID=$(api -X POST "$BASE/dashboards/validate" -H 'Content-Type: application/json' -d "$DASH_JSON" \
  | py 'import json,sys; r=json.load(sys.stdin)["result"]; print("ok" if r["valid"] else "INVALID "+json.dumps(r["errors"])[:400])')
if [ "$VALID" != ok ]; then echo "  $VALID" >&2; exit 1; fi
echo "  validated"

EXISTING_DASH=$(api "$BASE/dashboards" | DASH_NAME="$DASH_NAME" py '
import json, os, sys
print(next((d.get("id","") for d in json.load(sys.stdin)["result"] if d.get("name") == os.environ["DASH_NAME"]), ""))
')
if [ -n "$EXISTING_DASH" ]; then
  # PUT, not skip: the dashboard definition lives in this script, so a re-run
  # must converge the remote to it. Skipping would let a hand-edit in the UI
  # silently outlive the code that is supposed to define it.
  api -X PUT "$BASE/dashboards/$EXISTING_DASH" -H 'Content-Type: application/json' -d "$DASH_JSON_PUT" \
    | py 'import json,sys; d=json.load(sys.stdin); print("  updated" if not d.get("error") else "  FAILED: "+d["error"]); sys.exit(1 if d.get("error") else 0)'
else
  api -X POST "$BASE/dashboards" -H 'Content-Type: application/json' -d "$DASH_JSON" \
    | py 'import json,sys; d=json.load(sys.stdin); print("  created" if not d.get("error") else "  FAILED: "+d["error"]); sys.exit(1 if d.get("error") else 0)'
fi

# ---------------------------------------------------------- saved searches ----
add_search() {  # add_search <name> <sourceId> <select> <orderBy>
  local name="$1" sid="$2" select="$3" order="$4" existing
  existing=$(api "$BASE/saved-searches" | S="$name" py '
import json, os, sys
print(next((x.get("id","") for x in json.load(sys.stdin)["result"] if x.get("name") == os.environ["S"]), ""))
')
  if [ -n "$existing" ]; then echo "  '$name' exists"; return; fi
  api -X POST "$BASE/saved-searches" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$name\",\"sourceId\":\"$sid\",\"select\":\"$select\",\"where\":\"\",\"whereLanguage\":\"sql\",\"orderBy\":\"$order\"}" \
    | py 'import json,sys; d=json.load(sys.stdin); print("  created" if not d.get("error") else "  FAILED: "+d["error"]); sys.exit(1 if d.get("error") else 0)'
}

echo "saved searches:"
add_search "Peak minutes (accurate)" "$ACC_ID"     "minute, concurrent"             "concurrent DESC"
add_search "Busiest platforms"       "$ACC_DIM_ID" "minute, platform, concurrent"   "concurrent DESC"
add_search "Busiest content"         "$ACC_DIM_ID" "minute, content_id, concurrent" "concurrent DESC"

echo
echo "Open HyperDX -> dashboard '$DASH_NAME'."
echo "Set the range to 2026-07-14 -> 2026-07-26; the data is NOT 'now' and the"
echo "default last-15-minutes window renders every tile empty."
