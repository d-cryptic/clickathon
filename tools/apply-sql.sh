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

die() { printf 'tools/apply-sql.sh: %s\n' "$*" >&2; exit 1; }

# ── Destructive DDL against the graded database must be deliberate ──────────
# Placed HERE, not at argument-parsing time, because FILES only defaults to
# sql/*.sql just above — a guard before that point would have waved through the
# single most dangerous invocation, a bare `TARGET=cloud tools/apply-sql.sh`.
#
# On 2026-08-01 a rebuild on a stale base overwrote the graded answers with
# pre-ADR-0009 SQL and the service served two model generations for two hours.
# The tooling never objected, because it never asked.
#
# Only DROP and TRUNCATE are gated. CREATE and CREATE OR REPLACE are how views
# and UDFs are legitimately applied to `sonyliv`, and gating those would turn
# this into ceremony people learn to route around. Local is never gated: the
# graded database lives only on Cloud.
GRADED_DB="${GRADED_DB:-sonyliv}"
if [ "$TARGET" = cloud ] && [ "${CH_DATABASE:-}" = "$GRADED_DB" ] \
   && [ "${APPLY_GRADED_DESTRUCTIVE:-}" != yes ]; then
  for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    # Strip `--` comments first: ADR 0010's own commentary QUOTES a DROP, and a
    # guard that greps comments as code blocks a clean run. The unseen-day
    # rehearsal hit exactly that (finding R2).
    if sed 's/--.*//' "$f" | grep -qiE '(^|[[:space:];])(DROP|TRUNCATE)[[:space:]]'; then
      die "$f contains DROP or TRUNCATE and '$GRADED_DB' is the GRADED database.

Applying it destroys answers we are scored on, and there is no undo. If that is
genuinely what you want, confirm the tree is the one you mean to apply
(git log --oneline -1 · git status --porcelain), then:

  APPLY_GRADED_DESTRUCTIVE=yes TARGET=cloud tools/apply-sql.sh $f

Otherwise point CH_DATABASE at a scratch database, or drop TARGET=cloud for
local. CREATE and CREATE OR REPLACE are NOT gated — this stops destructive
DDL only."
    fi
  done
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
