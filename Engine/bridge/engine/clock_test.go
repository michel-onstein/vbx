package engine

import (
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

// The analysis clock is read on every call, never captured at load.
//
// The app keeps one session open for hours. bv 0.23+ pins "now" in label
// health, priority impact, drift alerts, ETA and readiness, and vbx follows it
// through robotNow() — but the analyzer is built once per load and defaults
// its own clock to the instant of construction. Pinning it there would make
// parity pass while freezing every staleness figure in the app at the moment
// the workspace was opened. Each test below opens one session and calls it at
// two different instants: a value captured at load would read the same twice.

// clockFixture is the shared graph plus a deferral that falls between the two
// instants the tests use, so readiness changes with the clock.
const clockFixture = `{"id":"a","title":"Alpha","status":"open","issue_type":"task","priority":1,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","labels":["core"],"dependencies":[{"issue_id":"a","depends_on_id":"b","type":"blocks"}]}
{"id":"b","title":"Bravo","status":"open","issue_type":"bug","priority":0,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","labels":["core"]}
{"id":"d","title":"Delta","status":"open","issue_type":"chore","priority":3,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","labels":["docs"],"defer_until":"2026-01-20T00:00:00Z"}
`

var (
	clockEarly = time.Date(2026, 1, 5, 0, 0, 0, 0, time.UTC)  // d deferred, nothing stale
	clockLate  = time.Date(2026, 2, 15, 0, 0, 0, 0, time.UTC) // d ready, everything 44 days idle
)

func setClock(t *testing.T, at time.Time) {
	t.Helper()
	t.Setenv("SOURCE_DATE_EPOCH", strconv.FormatInt(at.Unix(), 10))
}

func openClockFixture(t *testing.T) *Session {
	t.Helper()
	dir := t.TempDir()
	beads := filepath.Join(dir, ".beads")
	if err := os.MkdirAll(beads, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(beads, "issues.jsonl"), []byte(clockFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	// Loaded under the early clock, so anything captured at load is early.
	setClock(t, clockEarly)
	s, err := Open(OpenConfig{Path: dir, SkipPhase2: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)
	return s
}

func TestLabelHealthReadsTheClockPerCall(t *testing.T) {
	s := openClockFixture(t)

	type payload struct {
		Labels []struct {
			Label     string `json:"label"`
			Freshness struct {
				AvgDaysSinceUpdate float64 `json:"avg_days_since_update"`
			} `json:"freshness"`
		} `json:"labels"`
	}
	days := func() float64 {
		for _, l := range call[payload](t, s, "label_health", nil).Labels {
			if l.Label == "core" {
				return l.Freshness.AvgDaysSinceUpdate
			}
		}
		t.Fatal("no core label")
		return 0
	}

	early := days()
	setClock(t, clockLate)
	late := days()

	want := clockLate.Sub(clockEarly).Hours() / 24
	if got := late - early; got < want-0.001 || got > want+0.001 {
		t.Errorf("core freshness moved %.3f days between calls %.0f days apart; "+
			"the clock was captured rather than read", got, want)
	}
	// And the pin is honoured, not just some clock that moves.
	if want := clockEarly.Sub(time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)).Hours() / 24; early != want {
		t.Errorf("early freshness %.3f days, want %.0f from the pinned clock", early, want)
	}
}

func TestActionableReadsTheClockPerCall(t *testing.T) {
	s := openClockFixture(t)

	type payload struct {
		IDs      []string `json:"ids"`
		Deferred []string `json:"deferred"`
	}
	earlyPayload := call[payload](t, s, "actionable", nil)
	setClock(t, clockLate)
	latePayload := call[payload](t, s, "actionable", nil)
	early, late := earlyPayload.IDs, latePayload.IDs

	if slices.Contains(early, "d") {
		t.Errorf("d is deferred until 2026-01-20 but actionable on 2026-01-05: %v", early)
	}
	if !slices.Contains(late, "d") {
		t.Errorf("d's deferral passed on 2026-01-20 but it is not actionable on "+
			"2026-02-15 — the analyzer kept the clock it was loaded with: %v", late)
	}
	// The deferred list reads the same pinned instant, so it moves with it.
	if !slices.Contains(earlyPayload.Deferred, "d") {
		t.Errorf("d is deferred on 2026-01-05 but not listed: %v", earlyPayload.Deferred)
	}
	if slices.Contains(latePayload.Deferred, "d") {
		t.Errorf("d's deferral passed but it is still listed on 2026-02-15: %v", latePayload.Deferred)
	}
}

func TestImpactReadsTheClockPerCall(t *testing.T) {
	s := openClockFixture(t)

	type payload struct {
		Scores []struct {
			IssueID   string `json:"issue_id"`
			Breakdown struct {
				Staleness float64 `json:"staleness"`
			} `json:"breakdown"`
		} `json:"scores"`
	}
	staleness := func() float64 {
		for _, sc := range call[payload](t, s, "impact", nil).Scores {
			if sc.IssueID == "b" {
				return sc.Breakdown.Staleness
			}
		}
		t.Fatal("no score for b")
		return 0
	}

	early := staleness()
	setClock(t, clockLate)
	if late := staleness(); late <= early {
		t.Errorf("b's staleness is %.4f after 44 idle days and %.4f after 3; "+
			"impact is not reading the clock per call", late, early)
	}
}

func TestAlertsReadTheClockPerCall(t *testing.T) {
	s := openClockFixture(t)

	type payload struct {
		Alerts []struct {
			Message string `json:"message"`
		} `json:"alerts"`
	}
	inactive := func() []string {
		var out []string
		for _, a := range call[payload](t, s, "alerts", nil).Alerts {
			if strings.Contains(a.Message, "inactive for") {
				out = append(out, a.Message)
			}
		}
		return out
	}

	if early := inactive(); len(early) != 0 {
		t.Errorf("three days idle is not stale, yet: %v", early)
	}
	setClock(t, clockLate)
	late := inactive()
	if !slices.Contains(late, "Issue b inactive for 44 days") {
		t.Errorf("want b reported inactive for 44 days on 2026-02-15, got %v", late)
	}
}

// The robot envelope's timestamp is pinned too, as bv's is.
func TestRobotEnvelopeHonoursThePinnedClock(t *testing.T) {
	s := openClockFixture(t)
	setClock(t, clockLate)

	type payload struct {
		GeneratedAt string `json:"generated_at"`
	}
	if got := call[payload](t, s, "priority", nil).GeneratedAt; got != clockLate.Format(time.RFC3339) {
		t.Errorf("generated_at %q, want the pinned %q", got, clockLate.Format(time.RFC3339))
	}
}
