#!/usr/bin/env bash
# Emit a human release label plus a deterministic fingerprint of SQL that
# defines the state-machine/correction semantics. A semantic edit therefore
# cannot silently share a correction baseline with the previous model.
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$root_dir"

label=${MODEL_VERSION:-state-gated-v1}
if ! [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "MODEL_VERSION may contain only letters, numbers, dot, underscore, and hyphen" >&2
  exit 2
fi

model_files=(
  queries/materialize_intervals.sql
  queries/stage_finalizer_corrections.sql
  queries/stage_exact_tail.sql
)

for model_file in "${model_files[@]}"; do
  if [ ! -f "$model_file" ]; then
    echo "missing model file: $model_file" >&2
    exit 1
  fi
done

fingerprint=$(shasum -a 256 "${model_files[@]}" | shasum -a 256 | awk '{print substr($1, 1, 12)}')
printf '%s-%s\n' "$label" "$fingerprint"
