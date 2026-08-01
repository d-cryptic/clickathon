#!/usr/bin/env bash
# Create the application schema on a pre-provisioned target. Local Docker
# normally initializes this automatically; this command is required for Cloud.
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$root_dir"

target=${TARGET:-local}
if [ "$target" != local ] && [ "$target" != cloud ]; then
  echo "TARGET must be local or cloud" >&2
  exit 2
fi

TARGET="$target" "$root_dir/tools/ch-run.sh" --multiquery --file sql/00_schema.sql
TARGET="$target" "$root_dir/tools/ch-run.sh" --multiquery --file sql/10_intervals.sql

echo "schema deployed to TARGET=$target"
