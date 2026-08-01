#!/usr/bin/env bash
# Execute SQL against the selected ClickHouse target without exposing secrets.
# TARGET=local uses the Docker client; TARGET=cloud uses HTTPS and the Cloud
# credentials already described in .env.example.
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$root_dir"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

usage() {
  echo "usage: TARGET=local|cloud tools/ch-run.sh [--multiquery] [--param NAME=VALUE] [--setting NAME=VALUE] (--query SQL | --file PATH | --stdin)" >&2
}

target=${TARGET:-local}
multiquery=0
query=''
query_file=''
query_stdin=0
params=()
settings=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --multiquery) multiquery=1; shift ;;
    --param) params+=("${2:?missing NAME=VALUE}"); shift 2 ;;
    --setting) settings+=("${2:?missing NAME=VALUE}"); shift 2 ;;
    --query) query=${2:?missing SQL}; shift 2 ;;
    --file) query_file=${2:?missing path}; shift 2 ;;
    --stdin) query_stdin=1; shift ;;
    *) usage; exit 2 ;;
  esac
done

query_sources=0
[ -n "$query" ] && query_sources=$((query_sources + 1))
[ -n "$query_file" ] && query_sources=$((query_sources + 1))
[ "$query_stdin" = 1 ] && query_sources=$((query_sources + 1))
if [ "$query_sources" != 1 ]; then
  usage
  exit 2
fi

for param in "${params[@]}" "${settings[@]}"; do
  if [[ "$param" != *=* ]] || [ -z "${param%%=*}" ]; then
    echo "parameter must be NAME=VALUE" >&2
    exit 2
  fi
done

if [ -n "$query_file" ] && [ ! -f "$query_file" ]; then
  echo "SQL file does not exist: $query_file" >&2
  exit 2
fi

if [ "$target" = local ]; then
  container_name=${CH_CONTAINER:-ch}
  password=${CH_PASSWORD_LOCAL:?CH_PASSWORD_LOCAL must be set in .env or the environment}
  client_args=(docker exec -i "$container_name" clickhouse-client --user app --password "$password")
  if [ "$multiquery" = 1 ]; then
    client_args+=(--multiquery)
  fi
  for param in "${params[@]}"; do
    client_args+=("--param_${param%%=*}=${param#*=}")
  done
  for setting in "${settings[@]}"; do
    client_args+=("--${setting%%=*}=${setting#*=}")
  done
  if [ -n "$query_file" ]; then
    "${client_args[@]}" < "$query_file"
  elif [ "$query_stdin" = 1 ]; then
    "${client_args[@]}"
  else
    "${client_args[@]}" --query "$query"
  fi
  exit 0
fi

if [ "$target" != cloud ]; then
  echo "TARGET must be local or cloud" >&2
  exit 2
fi

host=${CH_HOST:?CH_HOST must be set for TARGET=cloud}
host=${host#https://}
host=${host#http://}
host=${host%/}
port=${CH_PORT:-8443}
database=${CH_DATABASE:?CH_DATABASE must be set for TARGET=cloud}
user=${CH_USER:?CH_USER must be set for TARGET=cloud}
password=${CH_PASSWORD:?CH_PASSWORD must be set for TARGET=cloud}

encode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read()), end="")'
}

endpoint="https://${host}:${port}/?database=$(printf '%s' "$database" | encode)"
if [ "$multiquery" = 1 ]; then
  endpoint+='&multiquery=1'
fi
for param in "${params[@]}"; do
  name=${param%%=*}
  value=${param#*=}
  endpoint+="&param_$(printf '%s' "$name" | encode)=$(printf '%s' "$value" | encode)"
done
for setting in "${settings[@]}"; do
  name=${setting%%=*}
  value=${setting#*=}
  endpoint+="&$(printf '%s' "$name" | encode)=$(printf '%s' "$value" | encode)"
done

if [ -n "$query_file" ]; then
  curl -sS --fail-with-body "$endpoint" --user "${user}:${password}" --data-binary "@$query_file"
elif [ "$query_stdin" = 1 ]; then
  curl -sS --fail-with-body "$endpoint" --user "${user}:${password}" --data-binary @-
else
  curl -sS --fail-with-body "$endpoint" --user "${user}:${password}" --data-binary "$query"
fi
