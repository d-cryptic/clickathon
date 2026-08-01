#!/usr/bin/env bash
# Check that the peak/average endpoint has the same arithmetic as the returned
# zero-filled minute curve for representative unfiltered and filtered queries.
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$root_dir"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

target=${TARGET:-local}

scalar() {
  TARGET="$target" "$root_dir/tools/ch-run.sh" --query "$1 FORMAT TSVRaw"
}

from=$(scalar "SELECT formatDateTime(toStartOfHour(max(event_timestamp)), '%F %T') FROM ev_raw")
to=$(scalar "SELECT formatDateTime(toStartOfMinute(max(event_timestamp)), '%F %T') FROM ev_raw")
platform=$(scalar "SELECT platform FROM ev_raw GROUP BY platform ORDER BY count() DESC LIMIT 1")
content_id=$(scalar "SELECT toString(content_id) FROM ev_raw GROUP BY content_id ORDER BY count() DESC LIMIT 1")

if ! [[ "$content_id" =~ ^-?[0-9]+$ ]]; then
  echo "most-active content id is not an Int64: $content_id" >&2
  exit 1
fi

video_type=$(TARGET="$target" "$root_dir/tools/ch-run.sh" \
  --param "content_id=$content_id" \
  --query "SELECT video_type FROM content_dim FINAL WHERE content_id = toInt64({content_id:String}) LIMIT 1 FORMAT TSVRaw")

if [ -z "$from" ] || [ -z "$to" ] || [ -z "$platform" ] || [ -z "$video_type" ]; then
  echo "cannot construct representative query shapes from loaded data" >&2
  exit 1
fi

assert_summary_matches_curve() {
  local name=$1
  shift

  local curve summary derived
  curve=$(TARGET="$target" "$root_dir/tools/query-concurrency.sh" --from "$from" --to "$to" "$@")
  summary=$(TARGET="$target" "$root_dir/tools/query-concurrency.sh" --from "$from" --to "$to" --summary "$@")
  derived=$(printf '%s\n' "$curve" | awk '
    BEGIN { peak = -1; total = 0; minutes = 0 }
    {
      if ($3 > peak) peak = $3
      total += $3
      minutes++
    }
    END { printf "%d\t%d\t%d", peak, total, minutes }
  ')

  if ! printf '%s\n' "$summary" | awk -v derived="$derived" -v name="$name" -F '\t' '
    BEGIN { split(derived, values, "\t") }
    $1 != values[1] || $3 != values[2] || $4 != values[3] || (sqrt(($2 - values[2] / values[3]) * ($2 - values[2] / values[3])) > 1e-9) {
      printf "%s: summary does not match curve (derived peak=%s total=%s minutes=%s; summary=%s)\n", name, values[1], values[2], values[3], $0 > "/dev/stderr"
      exit 1
    }
    { printf "%s: PASS peak=%s average=%s total=%s minutes=%s\n", name, $1, $2, $3, $4 }
  '; then
    exit 1
  fi
}

assert_summary_matches_curve all
assert_summary_matches_curve platform --platform "$platform"
assert_summary_matches_curve content --content-id "$content_id"
assert_summary_matches_curve video_type --video-type "$video_type"
