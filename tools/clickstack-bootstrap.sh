#!/usr/bin/env bash
# tools/clickstack-bootstrap.sh — headless ClickStack setup. No browser needed.
# OTLP 4317/4318 do NOT bind until a team exists, and the collector binds LATE, so poll.
set -euo pipefail
[ -f .env ] && set -a && . ./.env && set +a
: "${CS_PASSWORD:?set CS_PASSWORD in .env}"
BASE=http://localhost:8000
until curl -sf -o /dev/null "$BASE" 2>/dev/null || [ $((++i)) -gt 60 ]; do sleep 2; done

# 1. register — the route is at the ROOT, not under /api (a /api/... path 404s)
curl -sS -X POST "$BASE/register/password" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$CS_EMAIL\",\"password\":\"$CS_PASSWORD\",\"confirmPassword\":\"$CS_PASSWORD\"}" \
  -o /dev/null -w "register -> HTTP %{http_code}\n" || true

# 2. log in (303 + cookie) and read the ingestion key off /team
curl -sS -c /tmp/cs.jar -X POST "$BASE/login/password" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$CS_EMAIL\",\"password\":\"$CS_PASSWORD\"}" -o /dev/null -w "login -> HTTP %{http_code}\n"
KEY=$(curl -sS -b /tmp/cs.jar "$BASE/team" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("apiKey",""))')
[ -n "$KEY" ] || { echo "no apiKey returned"; exit 1; }

# 3. wait for the collector to actually accept traffic (it binds AFTER registration)
until curl -sf -o /dev/null -X POST http://localhost:4318/v1/traces \
        -H 'Content-Type: application/json' -H "authorization: $KEY" \
        --data-binary '{"resourceSpans":[]}'; do sleep 2; done

echo "CLICKSTACK_INGESTION_KEY=$KEY"
echo "  append that to .env; OTLP is live on 4317/4318 (401 without the key)"
