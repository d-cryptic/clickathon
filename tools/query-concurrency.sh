#!/usr/bin/env bash
# Read a minute curve or peak/average from the signed-delta serving layer.
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
  echo "usage: tools/query-concurrency.sh --from 'YYYY-MM-DD HH:MM:SS' --to 'YYYY-MM-DD HH:MM:SS' [--summary] [--platform VALUE] [--country VALUE] [--content-id VALUE] [--video-type VALUE] [--as-of-run N]" >&2
}

from=''
to=''
mode=curve
platform=''
country=''
content_id=''
video_type=''
as_of_run_sequence='18446744073709551615'

while [ "$#" -gt 0 ]; do
  case "$1" in
    --from) from=${2:?missing value for --from}; shift 2 ;;
    --to) to=${2:?missing value for --to}; shift 2 ;;
    --summary) mode=summary; shift ;;
    --platform) platform=${2:?missing value for --platform}; shift 2 ;;
    --country) country=${2:?missing value for --country}; shift 2 ;;
    --content-id) content_id=${2:?missing value for --content-id}; shift 2 ;;
    --video-type) video_type=${2:?missing value for --video-type}; shift 2 ;;
    --as-of-run) as_of_run_sequence=${2:?missing value for --as-of-run}; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

if [ -z "$from" ] || [ -z "$to" ]; then
  usage
  exit 2
fi

minute_pattern='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:00$'
if ! [[ "$from" =~ $minute_pattern ]] || ! [[ "$to" =~ $minute_pattern ]]; then
  echo "from and to must be UTC minute boundaries in YYYY-MM-DD HH:MM:00 form" >&2
  exit 2
fi

if [[ "$to" < "$from" ]]; then
  echo "to must be greater than or equal to from" >&2
  exit 2
fi

if ! [[ "$as_of_run_sequence" =~ ^[0-9]+$ ]]; then
  echo "as-of-run must be an unsigned integer" >&2
  exit 2
fi

query_file="queries/concurrency_${mode}.sql"
target=${TARGET:-local}

TARGET="$target" "$root_dir/tools/ch-run.sh" \
  --multiquery \
  --param "from=$from" \
  --param "to=$to" \
  --param "platform=$platform" \
  --param "country=$country" \
  --param "content_id=$content_id" \
  --param "video_type=$video_type" \
  --param "as_of_run_sequence=$as_of_run_sequence" \
  --file "$query_file"
