package config_test

import (
	"testing"

	"github.com/d-cryptic/clickathon/internal/config"
)

// The scheme-prefixed host is not hypothetical: it is exactly what the Cloud
// console hands you, it is what landed in .env, and it broke tools/ch with
// "could not resolve host: https". These cases are that bug, pinned.
func TestParseHost(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name     string
		in       string
		wantHost string
		wantPort int
	}{
		{"bare host", "abc.gcp.clickhouse.cloud", "abc.gcp.clickhouse.cloud", 0},
		{"https scheme as the console gives it", "https://abc.gcp.clickhouse.cloud", "abc.gcp.clickhouse.cloud", 0},
		{"http scheme", "http://localhost", "localhost", 0},
		{"scheme and port", "https://abc.gcp.clickhouse.cloud:8443", "abc.gcp.clickhouse.cloud", 8443},
		{"local url from .env", "http://localhost:8123", "localhost", 8123},
		{"trailing slash", "https://abc.clickhouse.cloud/", "abc.clickhouse.cloud", 0},
		{"path is dropped", "https://abc.clickhouse.cloud/?database=sonyliv", "abc.clickhouse.cloud", 0},
		{"surrounding whitespace", "  https://abc.clickhouse.cloud  ", "abc.clickhouse.cloud", 0},
		{"bare host with port", "localhost:9000", "localhost", 9000},
		{"empty", "", "", 0},
		// A non-numeric suffix after ':' is not a port. Splitting there would
		// silently corrupt the host, which is worse than passing it through.
		{"colon but not a port", "host:notaport", "host:notaport", 0},
		{"port out of range is not a port", "host:70000", "host:70000", 0},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			host, port := config.ParseHost(tc.in)
			if host != tc.wantHost {
				t.Errorf("ParseHost(%q) host = %q, want %q", tc.in, host, tc.wantHost)
			}
			if port != tc.wantPort {
				t.Errorf("ParseHost(%q) port = %d, want %d", tc.in, port, tc.wantPort)
			}
		})
	}
}

func TestLoadCloudRequiresCredentials(t *testing.T) {
	// Not parallel: t.Setenv forbids it.
	t.Setenv("CH_HOST", "")
	t.Setenv("CH_PASSWORD", "")

	if _, err := config.Load(config.TargetCloud); err == nil {
		t.Fatal("Load(cloud) with no CH_HOST returned nil error; want a named-variable error")
	}
}

func TestLoadCloudNormalizesHost(t *testing.T) {
	t.Setenv("CH_HOST", "https://abc.gcp.clickhouse.cloud")
	t.Setenv("CH_PASSWORD", "secret")
	t.Setenv("CH_PORT", "8443")
	t.Setenv("CH_DATABASE", "sonyliv")

	got, err := config.Load(config.TargetCloud)
	if err != nil {
		t.Fatalf("Load(cloud) = %v, want nil", err)
	}
	if want := "abc.gcp.clickhouse.cloud:8443"; got.Addr() != want {
		t.Errorf("Addr() = %q, want %q", got.Addr(), want)
	}
	if got.Database != "sonyliv" {
		t.Errorf("Database = %q, want %q", got.Database, "sonyliv")
	}
}

// The bug ADR 0018 removes, pinned: local used to fall back to CH_DATABASE —
// the graded Cloud database — so `sonyliv verify -target local` looked for
// `sonyliv` on localhost and 404ed. A set CH_DATABASE must be invisible to the
// local target: with CH_DATABASE_LOCAL unset, Load(local) fails loudly instead
// of borrowing the other target's database.
func TestLoadLocalNeverReadsCloudDatabase(t *testing.T) {
	t.Setenv("CH_DATABASE", "sonyliv")
	t.Setenv("CH_DATABASE_LOCAL", "")
	t.Setenv("CH_PASSWORD_LOCAL", "secret")

	if _, err := config.Load(config.TargetLocal); err == nil {
		t.Fatal("Load(local) with only CH_DATABASE set returned nil error; want a loud CH_DATABASE_LOCAL error, never a fallback to the Cloud database")
	}
}

func TestLoadLocalResolvesItsOwnDatabase(t *testing.T) {
	t.Setenv("CH_DATABASE", "sonyliv") // must be ignored
	t.Setenv("CH_DATABASE_LOCAL", "default")
	t.Setenv("CH_PASSWORD_LOCAL", "secret")
	t.Setenv("CH_LOCAL_URL", "http://localhost:8123")

	got, err := config.Load(config.TargetLocal)
	if err != nil {
		t.Fatalf("Load(local) = %v, want nil", err)
	}
	if got.Database != "default" {
		t.Errorf("Database = %q, want %q (CH_DATABASE_LOCAL, not CH_DATABASE)", got.Database, "default")
	}
	if want := "localhost:8123"; got.Addr() != want {
		t.Errorf("Addr() = %q, want %q", got.Addr(), want)
	}
}

// Cloud symmetrically requires its own database variable: an unset CH_DATABASE
// must fail at Load time, not produce a confident query against the server
// default database.
func TestLoadCloudRequiresDatabase(t *testing.T) {
	t.Setenv("CH_HOST", "abc.gcp.clickhouse.cloud")
	t.Setenv("CH_PASSWORD", "secret")
	t.Setenv("CH_DATABASE", "")

	if _, err := config.Load(config.TargetCloud); err == nil {
		t.Fatal("Load(cloud) with no CH_DATABASE returned nil error; want a named-variable error")
	}
}

func TestLoadRejectsUnknownTarget(t *testing.T) {
	t.Parallel()
	if _, err := config.Load(config.Target("staging")); err == nil {
		t.Fatal("Load(staging) returned nil error; want an error naming the valid targets")
	}
}

func TestTargetFromEnv(t *testing.T) {
	// Default must be local: an accidental run should never hit the graded
	// Cloud service.
	t.Setenv("TARGET", "")
	if got := config.TargetFromEnv(); got != config.TargetLocal {
		t.Errorf("TargetFromEnv() with TARGET unset = %q, want %q", got, config.TargetLocal)
	}

	t.Setenv("TARGET", "cloud")
	if got := config.TargetFromEnv(); got != config.TargetCloud {
		t.Errorf("TargetFromEnv() with TARGET=cloud = %q, want %q", got, config.TargetCloud)
	}
}
