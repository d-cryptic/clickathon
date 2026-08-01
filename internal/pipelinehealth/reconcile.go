package pipelinehealth

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// ReconcileMinute is one row of THE GATE's five-minute sample: truth
// recomputed from ev_raw against what the serving layer answered.
type ReconcileMinute struct {
	Minute          time.Time
	TruthFromEvRaw  int64
	ServedFromDelta int64
	Delta           int64
	Verdict         string // "PASS" or "MISMATCH"
}

// ReconcileEvidence is tools/reconcile.sh's output (evidence/reconcile.txt),
// parsed. This package reads that file rather than re-running
// sql/90_reconcile.sql itself: the gate's own script already writes
// deterministic, git-tracked evidence, and re-running the full ev_raw
// recompute here would (a) duplicate a ~900k-row scan on every observe call
// and (b) race the evidence file against whichever agent's own reconcile
// run is in flight. Freshness of the READING is exposed via GeneratedAt /
// the caller's own now() so staleness is visible rather than hidden.
type ReconcileEvidence struct {
	Path        string
	Target      string
	Commit      string
	GeneratedAt time.Time // evidence file's mtime
	Minutes     []ReconcileMinute
}

// Pass reports whether every sampled minute agreed. An evidence file with no
// parsed rows (e.g. reconcile.sh has never been run) is NOT a pass — Found
// on the caller side should be checked first.
func (e *ReconcileEvidence) Pass() bool {
	if len(e.Minutes) == 0 {
		return false
	}
	for _, m := range e.Minutes {
		if m.Verdict != "PASS" {
			return false
		}
	}
	return true
}

// MaxAbsDelta is the largest |served - truth| across the sample, the single
// number a dashboard tile would want if the gate is failing.
func (e *ReconcileEvidence) MaxAbsDelta() int64 {
	var m int64
	for _, r := range e.Minutes {
		d := r.Delta
		if d < 0 {
			d = -d
		}
		if d > m {
			m = d
		}
	}
	return m
}

var targetCommitRe = regexp.MustCompile(`target:\s*(\S+)\s+commit:\s*(\S+)`)

// ReadReconcileEvidence parses evidence/reconcile.txt. It returns
// (ReconcileEvidence{}, nil, false) — via the ok return — if the file does
// not exist yet, which is a legitimate state (a fresh clone before the first
// `make reconcile`), not an error.
func ReadReconcileEvidence(path string) (ReconcileEvidence, bool, error) {
	info, err := os.Stat(path)
	if os.IsNotExist(err) {
		return ReconcileEvidence{}, false, nil
	}
	if err != nil {
		return ReconcileEvidence{}, false, fmt.Errorf("stat %s: %w", path, err)
	}

	f, err := os.Open(path) // #nosec G304 -- path is an operator-controlled flag/default, not user input
	if err != nil {
		return ReconcileEvidence{}, false, fmt.Errorf("open %s: %w", path, err)
	}
	defer func() { _ = f.Close() }()

	ev := ReconcileEvidence{Path: path, GeneratedAt: info.ModTime()}
	inGate := false

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()

		if m := targetCommitRe.FindStringSubmatch(line); m != nil {
			ev.Target, ev.Commit = m[1], m[2]
			continue
		}
		if strings.HasPrefix(strings.TrimSpace(line), "== 1.") {
			inGate = true
			continue
		}
		if strings.HasPrefix(strings.TrimSpace(line), "== 2.") {
			inGate = false
			continue
		}
		if !inGate {
			continue
		}
		if row, ok := parseGateRow(line); ok {
			ev.Minutes = append(ev.Minutes, row)
		}
	}
	if err := scanner.Err(); err != nil {
		return ReconcileEvidence{}, false, fmt.Errorf("scan %s: %w", path, err)
	}
	return ev, true, nil
}

// parseGateRow parses one PrettyCompact data row of THE GATE's table, e.g.:
//
//  1. │ 2026-07-26 10:56:00 │              2887 │              2887 │     0 │ PASS    │
//
// split on the box-drawing '│' separator gives 7 fields: the row-number
// prefix, the 5 columns, and a trailing empty string after the closing pipe.
func parseGateRow(line string) (ReconcileMinute, bool) {
	if !strings.Contains(line, "│") {
		return ReconcileMinute{}, false
	}
	parts := strings.Split(line, "│")
	if len(parts) != 7 {
		return ReconcileMinute{}, false
	}

	minuteStr := strings.TrimSpace(parts[1])
	truthStr := strings.TrimSpace(parts[2])
	servedStr := strings.TrimSpace(parts[3])
	deltaStr := strings.TrimSpace(parts[4])
	verdict := strings.TrimSpace(parts[5])

	if verdict != "PASS" && verdict != "MISMATCH" {
		return ReconcileMinute{}, false
	}

	minute, err := time.Parse("2006-01-02 15:04:05", minuteStr)
	if err != nil {
		return ReconcileMinute{}, false
	}
	truth, err := strconv.ParseInt(truthStr, 10, 64)
	if err != nil {
		return ReconcileMinute{}, false
	}
	served, err := strconv.ParseInt(servedStr, 10, 64)
	if err != nil {
		return ReconcileMinute{}, false
	}
	delta, err := strconv.ParseInt(deltaStr, 10, 64)
	if err != nil {
		return ReconcileMinute{}, false
	}

	return ReconcileMinute{
		Minute:          minute,
		TruthFromEvRaw:  truth,
		ServedFromDelta: served,
		Delta:           delta,
		Verdict:         verdict,
	}, true
}
