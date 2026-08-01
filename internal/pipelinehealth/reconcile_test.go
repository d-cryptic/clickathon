package pipelinehealth_test

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/d-cryptic/clickathon/internal/pipelinehealth"
)

// realEvidence is a byte-for-byte copy of the format tools/reconcile.sh
// actually writes (evidence/reconcile.txt as of commit 34c3f05) — the parser
// is tested against the real box-drawing PrettyCompact output, not a
// simplified stand-in, because that formatting (the '│' split producing a
// trailing empty field) is exactly what broke a naive first attempt at this
// parser during development.
const realEvidence = `RECONCILE — serving layer vs ev_raw
target: cloud   commit: 34c3f05

== 1. THE GATE — truth recomputed from ev_raw, five minutes
   (peak, both data boundaries, two arbitrary; any non-zero delta is a failure)

   ┌──────────────minute─┬─truth_from_ev_raw─┬─served_from_delta─┬─delta─┬─verdict─┐
1. │ 2026-07-14 15:43:00 │                 1 │                 1 │     0 │ PASS    │
2. │ 2026-07-26 06:09:00 │                16 │                16 │     0 │ PASS    │
3. │ 2026-07-26 10:56:00 │              2887 │              2887 │     0 │ PASS    │
4. │ 2026-07-26 11:10:00 │              2450 │              2450 │     0 │ PASS    │
5. │ 2026-07-26 11:31:00 │                 5 │                 5 │     0 │ PASS    │
   └─────────────────────┴───────────────────┴───────────────────┴───────┴─────────┘

== 2. MODEL COMPARISON — the same minutes under three definitions

   ┌──────────────minute─┬─session_aware─┬─stateless─┬─naive_session_span─┬─naive_overcount─┬─pct_overcount─┐
1. │ 2026-07-14 15:43:00 │             1 │         1 │                  1 │               0 │             0 │
   └─────────────────────┴───────────────┴───────────┴────────────────────┴─────────────────┴───────────────┘
`

const mismatchEvidence = `RECONCILE — serving layer vs ev_raw
target: cloud   commit: deadbee

== 1. THE GATE — truth recomputed from ev_raw, five minutes
   (peak, both data boundaries, two arbitrary; any non-zero delta is a failure)

   ┌──────────────minute─┬─truth_from_ev_raw─┬─served_from_delta─┬─delta─┬─verdict─┐
1. │ 2026-07-14 15:43:00 │                 1 │                 1 │     0 │ PASS    │
2. │ 2026-07-26 10:56:00 │              2887 │              2924 │    37 │ MISMATCH│
   └─────────────────────┴───────────────────┴───────────────────┴───────┴─────────┘

== 2. MODEL COMPARISON — the same minutes under three definitions
`

func writeFixture(t *testing.T, contents string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "reconcile.txt")
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	return path
}

func TestReadReconcileEvidence_Pass(t *testing.T) {
	t.Parallel()
	path := writeFixture(t, realEvidence)

	ev, found, err := pipelinehealth.ReadReconcileEvidence(path)
	if err != nil {
		t.Fatalf("ReadReconcileEvidence() error = %v, want nil", err)
	}
	if !found {
		t.Fatal("found = false, want true")
	}
	if ev.Target != "cloud" || ev.Commit != "34c3f05" {
		t.Errorf("target/commit = %q/%q, want cloud/34c3f05", ev.Target, ev.Commit)
	}
	if len(ev.Minutes) != 5 {
		t.Fatalf("len(Minutes) = %d, want 5", len(ev.Minutes))
	}
	if !ev.Pass() {
		t.Error("Pass() = false, want true — every sampled row is PASS")
	}
	if got := ev.MaxAbsDelta(); got != 0 {
		t.Errorf("MaxAbsDelta() = %d, want 0", got)
	}

	// Row 3 is the documented peak: 2026-07-26 10:56:00, 2887.
	peak := ev.Minutes[2]
	wantMinute := time.Date(2026, 7, 26, 10, 56, 0, 0, time.UTC)
	if !peak.Minute.Equal(wantMinute) {
		t.Errorf("Minutes[2].Minute = %v, want %v", peak.Minute, wantMinute)
	}
	if peak.TruthFromEvRaw != 2887 || peak.ServedFromDelta != 2887 {
		t.Errorf("Minutes[2] truth/served = %d/%d, want 2887/2887", peak.TruthFromEvRaw, peak.ServedFromDelta)
	}

	// Section 2's rows must NOT leak into the parsed gate rows — they share
	// the same box-drawing shape and would silently double the count if the
	// section boundary were wrong.
	for _, m := range ev.Minutes {
		if m.Verdict != "PASS" {
			t.Errorf("unexpected non-PASS row leaked from section 2: %+v", m)
		}
	}
}

// TestReadReconcileEvidence_Mismatch pins the exact defect WALKTHROUGH.md
// documents as historically real (the incremental-absorption bug overcounted
// the peak by 37, 2924 vs 2887) — Pass() and MaxAbsDelta() must both surface
// it rather than silently averaging it away.
func TestReadReconcileEvidence_Mismatch(t *testing.T) {
	t.Parallel()
	path := writeFixture(t, mismatchEvidence)

	ev, found, err := pipelinehealth.ReadReconcileEvidence(path)
	if err != nil {
		t.Fatalf("ReadReconcileEvidence() error = %v, want nil", err)
	}
	if !found {
		t.Fatal("found = false, want true")
	}
	if ev.Pass() {
		t.Error("Pass() = true, want false — one row is MISMATCH")
	}
	if got := ev.MaxAbsDelta(); got != 37 {
		t.Errorf("MaxAbsDelta() = %d, want 37", got)
	}
}

func TestReadReconcileEvidence_NotFound(t *testing.T) {
	t.Parallel()
	_, found, err := pipelinehealth.ReadReconcileEvidence(filepath.Join(t.TempDir(), "does-not-exist.txt"))
	if err != nil {
		t.Fatalf("ReadReconcileEvidence() error = %v, want nil (missing file is a legitimate state)", err)
	}
	if found {
		t.Error("found = true, want false")
	}
}

func TestReconcileEvidence_PassOnEmptyIsFalse(t *testing.T) {
	t.Parallel()
	// A zero-value ReconcileEvidence (no parsed rows) must not read as a
	// pass — an empty file or a format change that silently parses zero
	// rows should never look identical to "everything agreed".
	var ev pipelinehealth.ReconcileEvidence
	if ev.Pass() {
		t.Error("Pass() on zero-value ReconcileEvidence = true, want false")
	}
}
