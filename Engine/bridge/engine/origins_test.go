package engine

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// fakeBRHelp is the part of `br update --help` bv's capability probe reads:
// the explicit-database flags it requires, and the atomic --claim.
const fakeBRHelp = "--db --json --no-auto-import --no-auto-flush --claim"

// liveTrackerWorkspace is the fixture graph inside a workspace bv accepts as
// a live tracker — metadata naming a database that exists and the export that
// is read — with a stand-in `br` first on PATH.
//
// The stand-in prints the help the probe wants and records every run in
// `runs`, so a test can prove whether the engine spawned it at all.
func liveTrackerWorkspace(t *testing.T) (dir, runs string) {
	t.Helper()
	dir = newFixtureWorkspace(t)
	beads := filepath.Join(dir, ".beads")
	metadata := `{"database":"beads.db","jsonl_export":"issues.jsonl"}`
	if err := os.WriteFile(filepath.Join(beads, "metadata.json"), []byte(metadata), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(beads, "beads.db"), nil, 0o644); err != nil {
		t.Fatal(err)
	}

	bin := t.TempDir()
	runs = filepath.Join(bin, "runs")
	script := "#!/bin/sh\necho \"$@\" >> '" + runs + "'\necho '" + fakeBRHelp + "'\n"
	if err := os.WriteFile(filepath.Join(bin, "br"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	return dir, runs
}

func openLive(t *testing.T, path string, live bool) *Session {
	t.Helper()
	s, err := Open(OpenConfig{Path: path, LiveTrackerActions: live})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)
	return s
}

// The app must never spawn `br`: the App Sandbox forbids it. The binding is
// the only engine path that would, so the stand-in must record no run at all.
func TestTheAppNeverSpawnsTheTracker(t *testing.T) {
	dir, runs := liveTrackerWorkspace(t)
	s := openLive(t, dir, false)
	_ = call[map[string]any](t, s, "triage", nil)
	_ = call[map[string]any](t, s, "next", nil)
	if _, err := s.Call("reload", nil); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(runs); err == nil {
		recorded, _ := os.ReadFile(runs)
		t.Fatalf("the app spawned br: %q", recorded)
	}
}

// The control for the test above: the same workspace, opened as vbx-cli
// opens it, does reach the tracker — so its silence is the setting, not a
// fixture bv rejected before it got that far.
func TestTheCLIAsksTheTrackerWhatItSupports(t *testing.T) {
	dir, runs := liveTrackerWorkspace(t)
	_ = openLive(t, dir, true)

	recorded, err := os.ReadFile(runs)
	if err != nil {
		t.Fatalf("the CLI never ran br: %v", err)
	}
	if !strings.Contains(string(recorded), "update --help") {
		t.Errorf("br ran with %q, not the capability probe", recorded)
	}
}

// What vbx-cli gets: bv 0.25's atomic claim, bound to the workspace's own
// database, for a pick that passes the gate.
func TestNextFromTheCLIClaimsAtomically(t *testing.T) {
	dir, _ := liveTrackerWorkspace(t)
	s := openLive(t, dir, true)
	out := call[nextPayload](t, s, "next", nil)

	if !out.Actionable {
		t.Fatalf("nothing claimable in a fixture with two ready beads: %+v", out)
	}
	if out.ID != "c" && out.ID != "d" {
		t.Errorf("offered %q, which is blocked", out.ID)
	}
	if out.Actions == nil || out.Actions.Claim == nil {
		t.Fatalf("no claim action: %+v", out.Actions)
	}
	argv := strings.Join(out.Actions.Claim.Argv, " ")
	if !strings.HasSuffix(argv, "update --json --claim -- "+out.ID) {
		t.Errorf("claim argv is %q", argv)
	}
	if !strings.Contains(argv, "--db "+filepath.Join(dir, ".beads", "beads.db")) &&
		!strings.Contains(argv, "--db /private"+filepath.Join(dir, ".beads", "beads.db")) {
		t.Errorf("claim is not bound to the workspace database: %q", argv)
	}
	// The old command claimed by setting the status, which is not atomic and
	// is not what bv emits any more.
	if strings.Contains(out.ClaimCommand, "--status=in_progress") || out.ClaimCommand == "" {
		t.Errorf("claim command is %q", out.ClaimCommand)
	}
	if !strings.Contains(out.ShowCommand, "'show'") {
		t.Errorf("show command is %q", out.ShowCommand)
	}
}

// Triage's recommendations carry the same actions: a claim for a claimable
// bead, a reason for one that is not.
func TestTriageFromTheCLICarriesActions(t *testing.T) {
	dir, _ := liveTrackerWorkspace(t)
	s := openLive(t, dir, true)

	type action struct {
		LocalID           string          `json:"local_id"`
		Claim             json.RawMessage `json:"claim"`
		Show              json.RawMessage `json:"show"`
		UnavailableReason string          `json:"unavailable_reason"`
	}
	out := call[struct {
		Recommendations []struct {
			ID        string `json:"id"`
			Claimable bool   `json:"claimable"`
			Actions   action `json:"actions"`
		} `json:"recommendations"`
	}](t, s, "triage", nil)

	if len(out.Recommendations) == 0 {
		t.Fatal("no recommendations")
	}
	for _, rec := range out.Recommendations {
		if rec.Actions.LocalID != rec.ID || len(rec.Actions.Show) == 0 {
			t.Errorf("%s: actions do not name it: %+v", rec.ID, rec.Actions)
		}
		if rec.Claimable != (len(rec.Actions.Claim) > 0) {
			t.Errorf("%s: claimable %v but claim %s", rec.ID, rec.Claimable, rec.Actions.Claim)
		}
	}
}

// In the app every recommendation says why it has no actions — an explained
// absence, never an empty object that reads as "nothing to say".
func TestTriageInTheAppExplainsMissingActions(t *testing.T) {
	s := openFixture(t)
	out := call[struct {
		Recommendations []struct {
			ID      string             `json:"id"`
			Actions model.IssueActions `json:"actions"`
		} `json:"recommendations"`
	}](t, s, "triage", nil)

	if len(out.Recommendations) == 0 {
		t.Fatal("no recommendations")
	}
	for _, rec := range out.Recommendations {
		if rec.Actions.Claim != nil || rec.Actions.Show != nil {
			t.Errorf("%s: the app emitted a command: %+v", rec.ID, rec.Actions)
		}
		if rec.Actions.LocalID != rec.ID || rec.Actions.UnavailableReason != appActionsUnavailable {
			t.Errorf("%s: actions are %+v", rec.ID, rec.Actions)
		}
	}
}

// A load that dropped a record cannot prove what is ready, so nothing from it
// is claimable — bv's source-authority gate.
func TestAPartialLoadClaimsNothing(t *testing.T) {
	dir, _ := liveTrackerWorkspace(t)
	jsonl := filepath.Join(dir, ".beads", "issues.jsonl")
	content, err := os.ReadFile(jsonl)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(jsonl, append(content, []byte("{not json\n")...), 0o644); err != nil {
		t.Fatal(err)
	}
	s := openLive(t, dir, true)

	next := call[nextPayload](t, s, "next", nil)
	if next.Actionable || next.ClaimCommand != "" {
		t.Errorf("a partial load produced a claim: %+v", next)
	}
	if len(next.Degraded) != 1 || next.Degraded[0].Code != "source_authority_incomplete" {
		t.Errorf("degraded is %+v", next.Degraded)
	}

	triage := call[struct {
		Recommendations []struct {
			ID        string             `json:"id"`
			Claimable bool               `json:"claimable"`
			Actions   model.IssueActions `json:"actions"`
		} `json:"recommendations"`
	}](t, s, "triage", nil)
	for _, rec := range triage.Recommendations {
		if rec.Claimable || rec.Actions.Claim != nil {
			t.Errorf("%s is claimable from a partial load", rec.ID)
		}
	}
}
