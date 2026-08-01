#!/usr/bin/env bash
# ============================================================================
# tools/publish.sh — THE FINALIZER. One incremental publication batch.
#
# This is the answer to "update handling: incrementally, or by recomputing?".
# tools/build-model.sh recomputes: TRUNCATE both tables, re-derive all of
# ev_raw. This script re-derives only the sessions that have RECEIVED EVENTS
# since its cursor, and appends the difference between what those sessions
# used to contribute to cc_minute_delta and what they contribute now
# (ADR 0006 correction-by-diff). Nothing is truncated. See ADR 0013.
#
#   tools/publish.sh --database sonyliv_pub                 # one batch
#   tools/publish.sh --database sonyliv_pub --loop 60       # every 60s
#   tools/publish.sh --database sonyliv_pub --sessions a,b  # force these
#   tools/publish.sh --database sonyliv_pub --status        # read-only
#
# THE DERIVATION SQL IS NOT REIMPLEMENTED HERE. It is sed-templated out of
# sql/30_build_intervals.sql and sql/40_deltas.sql — the same idiom
# tools/truncation-test.sh uses — so the incremental path provably cannot drift
# from the batch path. Every substitution is ASSERTED (see template_or_die):
# a sed anchor that silently stopped matching would turn the scoped read into a
# full scan, which is exactly the claim this script exists to make.
#
# ISOLATION. --database is mandatory and `sonyliv` is refused unless
# PUBLISH_ALLOW_PROD=1 is set explicitly. Nothing here is qualified with a
# database name, so the target is whatever --database says and nothing else.
#
# PREREQ: sql/12_publish.sql applied to that database.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

TARGET="${TARGET:-cloud}"
DB=""
LOOP=0
FORCE_SESSIONS=""
STATUS_ONLY=0
QUIET=0

# SETTLE — how old a marking must be before this run will consume it.
#
# marked_at is now64(3) evaluated when the insert runs, but the rows it produces
# become readable only when that insert commits. Consuming a marking whose
# insert is still in flight would digest part of it and then record it as done,
# losing the rest for ever. So a marking is eligible only once it is this many
# seconds old — the standard "leave the trailing window alone" rule.
#
# This is the ONE assumption in the design: no insert takes longer than
# PUBLISH_SETTLE_S between now64(3) being evaluated and all of its rows being
# visible. It is also the floor on publish lag, so it trades freshness directly.
#
# It is NOT a lookback, and the difference matters. An earlier version re-read
# the change log from `cursor - 5s` and, because the previous batch's marked_at
# sits exactly ON the cursor, re-claimed that entire batch every run — 6,659
# sessions re-derived to absorb 5. Exactness comes from cc_publish_consumed
# (which INSERTs have been digested), not from a fuzzy window.
SETTLE_S="${PUBLISH_SETTLE_S:-5}"

die() { printf '\npublish.sh FAILED: %s\n' "$*" >&2; exit 1; }
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

usage() { sed -n '2,26p' "$0" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --database)   [ $# -ge 2 ] || die "--database needs a name"; DB="$2"; shift 2 ;;
    --database=*) DB="${1#--database=}"; shift ;;
    --loop)       [ $# -ge 2 ] || die "--loop needs seconds"; LOOP="$2"; shift 2 ;;
    --sessions)   [ $# -ge 2 ] || die "--sessions needs a list"; FORCE_SESSIONS="$2"; shift 2 ;;
    --status)     STATUS_ONLY=1; shift ;;
    --quiet)      QUIET=1; shift ;;
    -h|--help)    usage ;;
    *)            die "unknown argument: $1" ;;
  esac
done

[ -n "$DB" ] || die "--database is mandatory. Refusing to guess where to write."
case "$DB" in *[!A-Za-z0-9_]* | "" | [0-9]*) die "not a usable database name: '$DB'" ;; esac
if [ "$DB" = "sonyliv" ] && [ "${PUBLISH_ALLOW_PROD:-0}" != "1" ]; then
  die "refusing to publish into the graded database 'sonyliv'.
Set PUBLISH_ALLOW_PROD=1 if that is genuinely what you want."
fi

ch_host() { local h="${CH_HOST:?CH_HOST unset — fill in .env}"; h="${h#https://}"; h="${h#http://}"; echo "${h%/}"; }

# ---------------------------------------------------------------------------
# q  <sql> [extra url params]        — run one statement, return its output
# qf <file> <query_id> [extra]       — run one statement from a file
#
# Both go over HTTP with ?database=$DB, so no statement in this script or in
# the templated SQL needs to name a database. A query_id is attached to the
# heavy statements so system.query_log can be read back for evidence.
# ---------------------------------------------------------------------------
q() {
  local sql="$1" extra="${2:-}"
  if [ "$TARGET" = cloud ]; then
    curl -sS --fail-with-body "https://$(ch_host):${CH_PORT}/?database=${DB}${extra}" \
      --user "${CH_USER}:${CH_PASSWORD}" --data-binary "$sql"
  else
    curl -sS --fail-with-body "${CH_LOCAL_URL}/?user=app&password=${CH_PASSWORD_LOCAL}&database=${DB}${extra}" \
      --data-binary "$sql"
  fi
}
qf() {
  local file="$1" qid="$2" extra="${3:-}"
  if [ "$TARGET" = cloud ]; then
    curl -sS --fail-with-body "https://$(ch_host):${CH_PORT}/?database=${DB}&query_id=${qid}${extra}" \
      --user "${CH_USER}:${CH_PASSWORD}" --data-binary "@${file}"
  else
    curl -sS --fail-with-body "${CH_LOCAL_URL}/?user=app&password=${CH_PASSWORD_LOCAL}&database=${DB}&query_id=${qid}${extra}" \
      --data-binary "@${file}"
  fi
}
qr() { q "$1 FORMAT TSVRaw"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# template_or_die <src> <dst> <marker> <sed args...>
#
# sed substitutions fail SILENTLY: an anchor that stops matching leaves the
# original line, and here the original lines are "FROM ev_raw" with no WHERE
# and "sum(d) AS delta" with no sign flip. Either one would produce a run that
# looks successful and is wrong — a full re-derivation billed as an incremental
# one, or a doubled contribution instead of a corrected one. So every template
# injects a marker comment and this function refuses to run a file that does
# not carry it.
# ---------------------------------------------------------------------------
template_or_die() {
  local src="$1" dst="$2" marker="$3"; shift 3
  sed "$@" "$src" > "$dst"
  grep -q "$marker" "$dst" || die "template of $src did not apply: marker $marker absent.
The sed anchors in this script no longer match that file. This is a HARD stop:
running it unscoped would silently re-derive every session."
  # Nothing here may name a database; --database decides the target.
  if grep -Eq '(INSERT[[:space:]]+INTO|DELETE[[:space:]]+FROM|TRUNCATE[[:space:]]+TABLE)[[:space:]]+[A-Za-z_]+\.' "$dst"; then
    die "templated $dst names a database in a write statement. Refusing."
  fi
}

# ---------------------------------------------------------------------------
# mark <run_id> <phase> <cursor_from> <cursor_to> <sessions> <rows> <ms> <note>
# The write-ahead log. Written AFTER the phase's statement returns.
# ---------------------------------------------------------------------------
mark() {
  q "INSERT INTO cc_publish_runs
       (run_id, phase, at, cursor_from, cursor_to, sessions, rows_written, elapsed_ms, note)
     VALUES ($1, '$2', now64(3), toDateTime64('$3',3), toDateTime64('$4',3), $5, $6, $7, '$8')" >/dev/null
}

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

# Rows written by a query_id, straight from the server's own log. This is the
# evidence, not a count we did ourselves.
written_rows() {
  q "SYSTEM FLUSH LOGS" >/dev/null 2>&1 || true
  qr "SELECT toString(ifNull(max(written_rows), 0)) FROM system.query_log
      WHERE query_id = '$1' AND type = 'QueryFinish'"
}

# ---------------------------------------------------------------------------
# STATUS
# ---------------------------------------------------------------------------
if [ "$STATUS_ONLY" = 1 ]; then
  q "SELECT * FROM v_cc_publish_lag FORMAT Vertical"
  exit 0
fi

# ---------------------------------------------------------------------------
# ONE BATCH
# ---------------------------------------------------------------------------
publish_once() {
  # -- resume an in-flight run, or claim a new one ---------------------------
  local inflight run_id phase cursor_from cursor_to sessions
  inflight="$(qr "SELECT toString(ifNull(min(run_id), 0)) FROM (
                    SELECT run_id FROM cc_publish_runs
                    GROUP BY run_id HAVING countIf(phase = 'committed') = 0)")"

  if [ "$inflight" != "0" ]; then
    run_id="$inflight"
    phase="$(qr "SELECT argMax(phase, at) FROM cc_publish_runs WHERE run_id = $run_id")"
    cursor_from="$(qr "SELECT toString(any(cursor_from)) FROM cc_publish_runs WHERE run_id = $run_id")"
    cursor_to="$(qr "SELECT toString(any(cursor_to))   FROM cc_publish_runs WHERE run_id = $run_id")"
    sessions="$(qr "SELECT toString(count()) FROM cc_publish_batch WHERE run_id = $run_id")"
    say "== resuming run $run_id from phase '$phase' ($sessions sessions)"
  else
    phase=""
    cursor_from="$(qr "SELECT toString(ifNull(max(cursor_to), toDateTime64(0,3)))
                       FROM cc_publish_runs WHERE phase = 'committed'")"

    if [ -n "$FORCE_SESSIONS" ]; then
      # Forced republication. The cursor does NOT move: this is a manual
      # correction, not a consumption of the queue.
      cursor_to="$cursor_from"
    else
      # Only markings that have SETTLED are eligible — see SETTLE_S above.
      cursor_to="$(qr "SELECT toString(ifNull(max(marked_at), toDateTime64(0,3)))
                       FROM session_dirty
                       WHERE marked_at <= now64(3) - INTERVAL $SETTLE_S SECOND")"
    fi

    run_id="$(now_ms)"

    # --- claim -------------------------------------------------------------
    # The read window. For each claimed session take the union of
    #   (a) the event-time span of the markings we are consuming, and
    #   (b) the span of its CURRENTLY PUBLISHED intervals.
    #
    # That union provably contains every event the session has, which is what
    # makes it safe to bound the ev_raw read by time as well as by session id:
    # a session's first interval STARTS at its first event (run_start is an
    # event timestamp) and its last interval ENDS at or after its last event
    # (TAIL_S only ever extends), so (b) covers everything published so far,
    # and (a) covers everything that has arrived since. A brand-new session has
    # no (b) and is covered entirely by (a).
    #
    # This is what lets the scoped read use ev_raw's ACTUAL sort key
    # (toStartOfHour(event_timestamp) first, ADR 0002) instead of depending on
    # the video_session_id projection that WALKTHROUGH §5 measured as not worth
    # shipping.
    #
    # The claim predicate is EXACT, not approximate: every settled marking in
    # [cursor_from, cursor_to] that this finalizer has not already digested,
    # and nothing else. cc_publish_consumed is what makes the boundary case
    # (a marking whose timestamp equals the cursor) decidable instead of a
    # choice between losing it and re-doing the whole previous batch.
    local where_dirty
    if [ -n "$FORCE_SESSIONS" ]; then
      local in_list; in_list="'$(printf '%s' "$FORCE_SESSIONS" | sed "s/,/','/g")'"
      where_dirty="video_session_id IN ($in_list)"
    else
      where_dirty="marked_at >= toDateTime64('$cursor_from',3)
                   AND marked_at <= toDateTime64('$cursor_to',3)
                   AND marked_at NOT IN (SELECT marked_at FROM cc_publish_consumed)"
    fi

    q "INSERT INTO cc_publish_batch (run_id, video_session_id, lo_event_ts, hi_event_ts)
       WITH
         claimed AS (
           SELECT video_session_id, min(min_event_ts) AS lo, max(max_event_ts) AS hi
           FROM session_dirty WHERE $where_dirty
           GROUP BY video_session_id),
         prior AS (
           SELECT video_session_id, min(interval_start) AS plo, max(interval_end) AS phi,
                  toUInt8(1) AS has
           FROM session_intervals FINAL
           WHERE video_session_id IN (SELECT video_session_id FROM claimed)
           GROUP BY video_session_id)
       SELECT $run_id, c.video_session_id,
              if(has = 1, least(c.lo, plo), c.lo),
              if(has = 1, greatest(c.hi, phi), c.hi)
       FROM claimed c LEFT JOIN prior p USING (video_session_id)" >/dev/null

    sessions="$(qr "SELECT toString(count()) FROM cc_publish_batch WHERE run_id = $run_id")"
    if [ "$sessions" = "0" ]; then
      say "== nothing to publish (0 sessions claimed)"
      q "ALTER TABLE cc_publish_batch DROP PARTITION $run_id" >/dev/null 2>&1 || true
      return 0
    fi
    # Record WHICH inserts this run digested, before any of them is acted on.
    # Written at claim time, not at commit: a run that dies mid-flight is
    # resumed from cc_publish_batch, so these markings must not be handed to a
    # second run as well.
    if [ -z "$FORCE_SESSIONS" ]; then
      q "INSERT INTO cc_publish_consumed (marked_at, run_id)
         SELECT DISTINCT marked_at, $run_id FROM session_dirty
         WHERE marked_at >= toDateTime64('$cursor_from',3)
           AND marked_at <= toDateTime64('$cursor_to',3)" >/dev/null
    fi

    mark "$run_id" claimed "$cursor_from" "$cursor_to" "$sessions" 0 0 ""
    phase=claimed
    say "== run $run_id  ·  $sessions session(s) claimed  ·  cursor $cursor_from -> $cursor_to"
  fi

  local LO HI BV SCOPE t0 t1 rows
  LO="$(qr "SELECT toString(min(lo_event_ts)) FROM cc_publish_batch WHERE run_id = $run_id")"
  HI="$(qr "SELECT toString(max(hi_event_ts)) FROM cc_publish_batch WHERE run_id = $run_id")"
  SCOPE="video_session_id IN (SELECT video_session_id FROM cc_publish_batch WHERE run_id = $run_id)"

  # build_version must be monotonic AND must never collide with a build issued
  # in the same second — two runs a few hundred ms apart would otherwise stamp
  # the same value and ReplacingMergeTree(build_version) could not tell the new
  # derivation from the old. Kept in SECONDS, the same unit
  # tools/build-model.sh uses, so a later full rebuild still outranks us.
  BV="$(qr "SELECT toString(greatest(toUInt64(toUnixTimestamp(now())),
                                     toUInt64(ifNull(max(build_version), 0)) + 1))
            FROM session_intervals")"

  # -- PHASE: negate --------------------------------------------------------
  # Append -deltas(intervals_old(batch)). Must run BEFORE the new derivation
  # is promoted, because it reads session_intervals FINAL.
  if [ "$phase" = claimed ]; then
    template_or_die sql/40_deltas.sql "$TMP/negate.sql" 'PUBLISH_NEGATE' \
      -e "s|^    FROM session_intervals FINAL\$|    FROM session_intervals FINAL WHERE $SCOPE /*PUBLISH_SCOPE*/|" \
      -e "s|^    sum(d)  AS delta,\$|    -sum(d)  AS delta, /*PUBLISH_NEGATE*/|" \
      -e "s|^    sum(op) AS starts,\$|    -sum(op) AS starts,|" \
      -e "s|^    sum(cl) AS ends\$|    -sum(cl) AS ends|"
    grep -q 'PUBLISH_SCOPE' "$TMP/negate.sql" || die "negate template lost its scope"
    t0=$(now_ms)
    qf "$TMP/negate.sql" "publish-${run_id}-negate" "&insert_deduplication_token=${run_id}:negate" >/dev/null
    t1=$(now_ms); rows="$(written_rows "publish-${run_id}-negate")"
    mark "$run_id" negated "$cursor_from" "$cursor_to" "$sessions" "$rows" "$((t1-t0))" ""
    say "   negated   ${rows} corrective delta rows   $((t1-t0)) ms"
    phase=negated
  fi

  # -- PHASE: derive --------------------------------------------------------
  # Re-derive the batch's sessions from ev_raw, scoped by session id AND by the
  # event-time window computed above.
  if [ "$phase" = negated ]; then
    template_or_die sql/30_build_intervals.sql "$TMP/derive.sql" 'PUBLISH_SCOPE' \
      -e "s|^        FROM ev_raw\$|        FROM ev_raw WHERE $SCOPE AND event_timestamp >= toDateTime64('$LO',3) AND event_timestamp <= toDateTime64('$HI',3) /*PUBLISH_SCOPE*/|" \
      -e "s|^        toUInt64(toUnixTimestamp(now())) AS build_version,\$|        toUInt64($BV) AS build_version, /*PUBLISH_BV*/|"
    grep -q 'PUBLISH_BV' "$TMP/derive.sql" || die "derive template lost its build_version override"
    t0=$(now_ms)
    qf "$TMP/derive.sql" "publish-${run_id}-derive" "&insert_deduplication_token=${run_id}:derive" >/dev/null
    t1=$(now_ms); rows="$(written_rows "publish-${run_id}-derive")"
    mark "$run_id" derived "$cursor_from" "$cursor_to" "$sessions" "$rows" "$((t1-t0))" "bv=$BV window=$LO..$HI"
    say "   derived   ${rows} intervals   $((t1-t0)) ms   (window $LO .. $HI)"
    phase=derived
  fi

  # -- PHASE: prune ---------------------------------------------------------
  # Remove every superseded row of the batch's sessions. ReplacingMergeTree
  # replaces a KEY; it cannot delete one, and a re-derivation can legitimately
  # make an interval_start vanish (a straggler landing inside a gap merges two
  # runs into one). Without this the orphan survives FINAL for ever AND the
  # next run's negation would negate deltas that were never published.
  if [ "$phase" = derived ]; then
    t0=$(now_ms)
    q "DELETE FROM session_intervals WHERE $SCOPE AND build_version < $BV" \
      "&query_id=publish-${run_id}-prune" >/dev/null
    t1=$(now_ms)
    mark "$run_id" pruned "$cursor_from" "$cursor_to" "$sessions" 0 "$((t1-t0))" ""
    say "   pruned    superseded intervals   $((t1-t0)) ms"
    phase=pruned
  fi

  # -- PHASE: emit ----------------------------------------------------------
  # Append +deltas(intervals_new(batch)). Identical SQL to the negate phase
  # with the sign left alone — that symmetry is the correctness argument.
  if [ "$phase" = pruned ]; then
    template_or_die sql/40_deltas.sql "$TMP/emit.sql" 'PUBLISH_SCOPE' \
      -e "s|^    FROM session_intervals FINAL\$|    FROM session_intervals FINAL WHERE $SCOPE /*PUBLISH_SCOPE*/|"
    t0=$(now_ms)
    qf "$TMP/emit.sql" "publish-${run_id}-emit" "&insert_deduplication_token=${run_id}:emit" >/dev/null
    t1=$(now_ms); rows="$(written_rows "publish-${run_id}-emit")"
    mark "$run_id" emitted "$cursor_from" "$cursor_to" "$sessions" "$rows" "$((t1-t0))" ""
    say "   emitted   ${rows} delta rows   $((t1-t0)) ms"
    phase=emitted
  fi

  # -- PHASE: commit --------------------------------------------------------
  if [ "$phase" = emitted ]; then
    mark "$run_id" committed "$cursor_from" "$cursor_to" "$sessions" 0 0 ""
    say "   committed cursor now $cursor_to"
  fi
}

if [ "$LOOP" != 0 ]; then
  say "== publishing into '$DB' every ${LOOP}s (ctrl-c to stop)"
  while true; do publish_once; sleep "$LOOP"; done
else
  publish_once
fi
