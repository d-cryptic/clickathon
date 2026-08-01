#!/usr/bin/env bash
# A local, target-scoped publication fence. This serializes operators on one
# host; production still requires the external fenced lease in ADR 0014.

finalizer_lock_dir=''

finalizer_lock_acquire() {
  local target=${1:?target is required}
  local identity=${2:?target identity is required}
  local lock_root=${TMPDIR:-/tmp}

  case "$target" in
    local|cloud) ;;
    *) echo "unsupported finalizer lock target: $target" >&2; return 2 ;;
  esac
  case "$identity" in
    ''|*[!A-Za-z0-9_.-]*)
      echo "finalizer lock identity must contain only letters, digits, dot, underscore, or dash" >&2
      return 2
      ;;
  esac
  case "$lock_root" in
    /*) ;;
    *) echo "TMPDIR must be an absolute path for the finalizer lock" >&2; return 2 ;;
  esac

  finalizer_lock_dir="$lock_root/clickathon-finalizer-$target-$identity.lock"
  if ! mkdir "$finalizer_lock_dir" 2>/dev/null; then
    echo "another local operator holds $finalizer_lock_dir; inspect it before retrying" >&2
    return 1
  fi
  trap finalizer_lock_release EXIT
  trap finalizer_lock_interrupted INT TERM
}

finalizer_lock_release() {
  if [ -n "${finalizer_lock_dir:-}" ] && [ -d "$finalizer_lock_dir" ]; then
    if ! rmdir "$finalizer_lock_dir"; then
      echo "could not release finalizer lock $finalizer_lock_dir; inspect it before retrying" >&2
    fi
  fi
}

finalizer_lock_interrupted() {
  finalizer_lock_release
  exit 130
}
