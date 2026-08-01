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
#   tools/apply-sql.sh                      # every sql/*.sql to local
#   TARGET=cloud tools/apply-sql.sh         # every sql/*.sql to Cloud
#   TARGET=cloud tools/apply-sql.sh sql/20_views.sql
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

TARGET="${TARGET:-local}"

# The Cloud console hands you https://xxx.clickhouse.cloud; we add the scheme
# ourselves, so strip it. Same normalisation as tools/ch and tools/load.sh.
ch_host() { local h="${CH_HOST:?CH_HOST unset — fill in .env}"; h="${h#https://}"; h="${h#http://}"; echo "${h%/}"; }

# Files: whatever was passed, else every sql/*.sql in lexical order. 05_users.sh
# is a shell script, not SQL, so the glob correctly skips it.
if [ $# -gt 0 ]; then
  FILES=("$@")
else
  FILES=(sql/*.sql)
fi

apply() {  # apply <file>
  local f="$1"
  if [ "$TARGET" = cloud ]; then
    # Native protocol on 9440 (not CH_PORT, which is the HTTPS port): the
    # client speaks native, and multi-statement needs the client.
    docker exec -i -e CLICKHOUSE_PASSWORD="$CH_PASSWORD" ch clickhouse-client \
      --host "$(ch_host)" --port 9440 --secure --user "$CH_USER" \
      --database "$CH_DATABASE" --multiquery < "$f"
  else
    docker exec -i ch clickhouse-client --multiquery < "$f"
  fi
}

if [ "$TARGET" = cloud ]; then
  echo "applying to CLOUD: $(ch_host)/${CH_DATABASE}"
else
  echo "applying to LOCAL: docker exec ch"
fi

for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "no such file: $f" >&2; exit 1; }
  printf '  %-24s ... ' "$f"
  if apply "$f"; then echo "ok"; else echo "FAILED"; exit 1; fi
done

echo "done."
