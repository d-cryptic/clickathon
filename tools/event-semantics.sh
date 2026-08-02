#!/usr/bin/env bash
# tools/event-semantics.sh — the event-semantics contract, rendered and policed (ADR 0033).
#
# ONE source of truth: contracts/event_semantics.tsv declares what every
# (event_type, event) pair MEANS. This script renders that TSV into the SQL that
# consumes it and then PROVES the two never drift:
#
#   --render        print the generated SQL block to stdout
#   --pairs         print ('type','event'),... for queries/validate_source_contract.sql
#   --check         fail if any consuming file's block differs from the TSV (exit 1)
#   --write         rewrite the blocks in place from the TSV
#
# Consuming files (both carry the block verbatim, between the sentinels below):
#   sql/30_build_intervals.sql   the model
#   sql/90_reconcile.sql         the gate
#
# WHY INLINE AND NOT A PLACEHOLDER: every sql/*.sql in this repo runs standalone
# through tools/ch. queries/validate_source_contract.sql already pays the price
# of a render-time placeholder ("bare execution of this file fails") and says so
# in its own header. The model and the gate must not acquire that property — a
# rebuild at 2am must be `tools/ch "$(cat sql/30_build_intervals.sql)"`. So the
# contract is inlined, and --check (wired into tools/test-all.sh) is what makes
# the duplication safe: drift is a test failure, not a silent divergence.
#
# WHY THE GATE SHARES IT: the same reason UNCLOSED_PAUSE_TO_RUN_END and
# POINT_ACTIVITY_COUNTS are shared constants — sharing the SPEC is correct,
# sharing the IMPLEMENTATION is not. sql/90 still derives truth from ev_raw with
# window functions. Note what that means and does not mean: a gate that shares
# the vocabulary cannot catch a WRONG contract, only a DIVERGENT one. The defence
# against a wrong contract is tools/validate-source-contract.sh probe 8, which
# fires at load on any pair the contract does not declare (doubts/11).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTRACT="$ROOT/contracts/event_semantics.tsv"
FILES=("sql/30_build_intervals.sql" "sql/90_reconcile.sql")
BEGIN='    -- >>> BEGIN GENERATED from contracts/event_semantics.tsv — tools/event-semantics.sh --write'
END='    -- <<< END GENERATED'

die() { printf 'event-semantics: %s\n' "$*" >&2; exit 2; }
[ -f "$CONTRACT" ] || die "missing $CONTRACT — the contract is the source of truth (ADR 0033)"

# ---------------------------------------------------------------- rendering --
# perl, not sed: BSD sed burned us before (RUNBOOK R1). Single quotes are doubled
# for SQL. Rows are emitted in file order, so the TSV's sort IS the diff order.
render_block() {
  printf '%s\n' "$BEGIN"
  perl -e '
    my (@sem, @pause, @resume, @end);
    open my $fh, "<", $ARGV[0] or die;
    while (<$fh>) {
      next if $. == 1; s/\r?\n$//; next unless length;
      my @f = split /\t/;
      die "row $.: needs event_type\tevent\tclass\taction\n" unless defined $f[3];
      for (@f[0..3]) { s/\x27/\x27\x27/g }
      push @sem, "(\x27$f[0]\x27,\x27$f[1]\x27,\x27$f[2]\x27)";
      push @pause,  "\x27$f[1]\x27" if $f[3] eq "pause";
      push @resume, "\x27$f[1]\x27" if $f[3] eq "resume";
      push @end,    "\x27$f[0]\x27" if $f[3] eq "end";
    }
    die "contract declares no liveness pairs\n" unless @sem;
    die "contract declares no pause marker\n"   unless @pause;
    die "contract declares no resume marker\n"  unless @resume;
    die "contract declares no end marker\n"     unless @end;
    my @uniq = do { my %s; grep { !$s{$_}++ } @_ };
    print "    [", join(",\n     ", @sem), "] AS EVENT_SEMANTICS,\n";
    my %p; my @pu = grep { !$p{$_}++ } @pause;
    my %r; my @ru = grep { !$r{$_}++ } @resume;
    my %e; my @eu = grep { !$e{$_}++ } @end;
    print "    [", join(",", @pu),  "] AS PAUSE_EVENTS,\n";
    print "    [", join(",", @ru),  "] AS RESUME_EVENTS,\n";
    print "    [", join(",", @eu),  "] AS END_TYPES,\n";
  ' "$CONTRACT"
  printf '%s\n' "$END"
}

render_pairs() {
  perl -ne '
    next if $. == 1; s/\r?\n$//; next unless length;
    my @f = split /\t/; next unless defined $f[1] && length $f[0];
    for (@f[0,1]) { s/\x27/\x27\x27/g }
    push @p, "(\x27$f[0]\x27,\x27$f[1]\x27)";
    END { print join(",", @p) }' "$CONTRACT"
}

extract_block() { # $1 = file
  perl -ne 'if (/^\s*-- >>> BEGIN GENERATED/) { $in=1 } if ($in) { print } if (/^\s*-- <<< END GENERATED/) { $in=0 }' "$1"
}

MODE="${1:---check}"
case "$MODE" in
  --render) render_block ;;
  --pairs)  render_pairs ;;
  --check)
    WANT=$(render_block)
    RC=0
    POLICIES=""
    for f in "${FILES[@]}"; do
      [ -f "$ROOT/$f" ] || { printf 'event-semantics: FAIL %s is missing\n' "$f" >&2; RC=1; continue; }
      GOT=$(extract_block "$ROOT/$f")
      if [ -z "$GOT" ]; then
        printf 'event-semantics: FAIL %s carries no generated block — run --write\n' "$f" >&2; RC=1; continue
      fi
      if [ "$GOT" != "$WANT" ]; then
        printf 'event-semantics: FAIL %s has drifted from contracts/event_semantics.tsv\n' "$f" >&2
        diff <(printf '%s\n' "$WANT") <(printf '%s\n' "$GOT") | head -20 >&2 || true
        RC=1
      fi
      # The POLICY line is hand-edited (it is the operator's lever), but it must
      # be the SAME hand-edit in both files, or model and gate answer different
      # questions and the gate's agreement means nothing.
      P=$(perl -ne 'print "$1\n" if /^\s*(\[[^\]]*\])\s+AS LIVENESS_CLASSES,/' "$ROOT/$f")
      [ -n "$P" ] || { printf 'event-semantics: FAIL %s declares no LIVENESS_CLASSES policy\n' "$f" >&2; RC=1; continue; }
      POLICIES="${POLICIES}${P}"$'\n'
    done
    if [ "$(printf '%s' "$POLICIES" | sort -u | grep -c '')" -gt 1 ]; then
      printf 'event-semantics: FAIL model and gate declare DIFFERENT LIVENESS_CLASSES:\n%s' "$POLICIES" >&2
      RC=1
    fi
    if [ "$RC" = 0 ]; then
      printf 'event-semantics: OK — %s pairs, policy %s, in sync across %s\n' \
        "$(($(grep -c '' "$CONTRACT") - 1))" "$(printf '%s' "$POLICIES" | head -1)" "${FILES[*]}"
    fi
    exit "$RC" ;;
  --write)
    WANT=$(render_block)
    for f in "${FILES[@]}"; do
      [ -f "$ROOT/$f" ] || die "missing $ROOT/$f"
      extract_block "$ROOT/$f" | grep -q 'BEGIN GENERATED' \
        || die "$f has no BEGIN/END GENERATED sentinels — add them by hand once, then --write owns the body"
      WANT="$WANT" perl -0777 -pe 's/^\s*-- >>> BEGIN GENERATED.*?-- <<< END GENERATED\n/$ENV{WANT}\n/ms' \
        "$ROOT/$f" > "$ROOT/$f.tmp" && mv "$ROOT/$f.tmp" "$ROOT/$f"
      printf 'event-semantics: wrote %s\n' "$f"
    done ;;
  -h|--help) sed -n '2,30p' "$0" ;;
  *) die "unknown mode: $MODE (--render | --pairs | --check | --write)" ;;
esac
