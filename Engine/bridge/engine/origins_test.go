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
	markLiveTracker(t, filepath.Join(dir, ".beads"))
	return dir, standInTrackers(t)
}

// markLiveTracker makes a beads directory one bv binds to `br`: metadata
// naming a database that exists, and the export that is read.
func markLiveTracker(t *testing.T, beads string) {
	t.Helper()
	metadata := `{"database":"beads.db","jsonl_export":"issues.jsonl"}`
	if err := os.WriteFile(filepath.Join(beads, "metadata.json"), []byte(metadata), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(beads, "beads.db"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
}

// standInTrackers puts a stand-in `br` and `bd` first on PATH. Each prints the
// help bv's capability probe wants and appends its name and arguments to the
// returned file, which exists only once one of them has run.
func standInTrackers(t *testing.T) (runs string) {
	t.Helper()
	bin := t.TempDir()
	runs = filepath.Join(bin, "runs")
	for _, name := range []string{"br", "bd"} {
		script := "#!/bin/sh\necho \"" + name + " $@\" >> '" + runs + "'\necho '" + fakeBRHelp + "'\n"
		if err := os.WriteFile(filepath.Join(bin, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	return runs
}

// liveTrackerMultiRepo is the two-repository workspace with `api` a `br`
// tracker and `web` a Dolt-backed `bd` one — the second is what makes bv's
// workspace loader refresh the export with `bd export` as well as probe.
func liveTrackerMultiRepo(t *testing.T) (root, runs string) {
	t.Helper()
	root = multiRepoWorkspace(t)
	markLiveTracker(t, filepath.Join(root, "api", ".beads"))
	if err := os.MkdirAll(filepath.Join(root, "web", ".beads", "dolt"), 0o755); err != nil {
		t.Fatal(err)
	}
	return root, standInTrackers(t)
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

// The same rule for a multi-repository workspace. bv's workspace loader binds
// origins inside itself, per repository, and refreshes a Dolt repository's
// export with `bd export` — so the app cannot use it as it stands. See
// BUGS.md, 2026-10-01.
func TestTheAppNeverSpawnsTheTrackerForAWorkspace(t *testing.T) {
	root, runs := liveTrackerMultiRepo(t)
	s := openLive(t, root, false)
	_ = call[map[string]any](t, s, "triage", nil)
	_ = call[map[string]any](t, s, "next", nil)
	if _, err := s.Call("reload", nil); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(runs); err == nil {
		recorded, _ := os.ReadFile(runs)
		t.Fatalf("the app spawned a tracker: %q", recorded)
	}
	// Every bead still says why it has no actions, under its local id.
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
		if rec.Actions.UnavailableReason != appActionsUnavailable || rec.Actions.Claim != nil {
			t.Errorf("%s: actions are %+v", rec.ID, rec.Actions)
		}
		if !strings.HasSuffix(rec.ID, "-"+rec.Actions.LocalID) {
			t.Errorf("%s: local id is %q", rec.ID, rec.Actions.LocalID)
		}
	}
}

// Its control: vbx-cli, on the same workspace, probes the `br` tracker and
// refreshes the Dolt export, exactly as bv's workspace loader does.
func TestTheCLIAsksEveryWorkspaceTracker(t *testing.T) {
	root, runs := liveTrackerMultiRepo(t)
	_ = openLive(t, root, true)

	recorded, err := os.ReadFile(runs)
	if err != nil {
		t.Fatalf("the CLI never ran a tracker: %v", err)
	}
	for _, want := range []string{"br update --help", "bd export -o"} {
		if !strings.Contains(string(recorded), want) {
			t.Errorf("no %q among %q", want, recorded)
		}
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
	if !strings.Contains(string(recorded), "br update --help") {
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

// liveTrackerTwoRepo is multiRepoWorkspace with both members bound to a
// stand-in `br`, so vbx-cli emits claims for either member's beads.
func liveTrackerTwoRepo(t *testing.T) (root string) {
	t.Helper()
	root = multiRepoWorkspace(t)
	markLiveTracker(t, filepath.Join(root, "api", ".beads"))
	markLiveTracker(t, filepath.Join(root, "web", ".beads"))
	standInTrackers(t)
	return root
}

// A workspace member that loaded but dropped a malformed line withholds every
// claim, as bv 0.25.2's source authority does: its ClaimSafe is false when any
// member has errors, not only when one fails to load. vbx counted only the
// failures, so --robot-next claimed from a partial graph. vbx-koc.
func TestAWorkspaceMemberThatDroppedARecordClaimsNothing(t *testing.T) {
	// The control: the same workspace, clean, does claim.
	clean := openLive(t, liveTrackerTwoRepo(t), true)
	if next := call[nextPayload](t, clean, "next", nil); !next.Actionable || next.ClaimCommand == "" {
		t.Fatalf("the clean workspace claims nothing, so the test proves nothing: %+v", next)
	}

	root := liveTrackerTwoRepo(t)
	web := filepath.Join(root, "web", ".beads", "issues.jsonl")
	file, err := os.OpenFile(web, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString("{not json\n"); err != nil {
		t.Fatal(err)
	}
	file.Close()
	s := openLive(t, root, true)

	next := call[nextPayload](t, s, "next", nil)
	if next.Actionable || next.ClaimCommand != "" {
		t.Errorf("a workspace with a dropped record produced a claim: %+v", next)
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
	if len(triage.Recommendations) == 0 {
		t.Fatal("no recommendations")
	}
	for _, rec := range triage.Recommendations {
		if rec.Claimable || rec.Actions.Claim != nil {
			t.Errorf("%s is claimable from a workspace with a dropped record", rec.ID)
		}
	}
}

// A reload that adds the dropped record to an otherwise unchanged workspace
// withdraws the claim too: the bead set is the same, so only the accounting
// path sees it.
func TestAWorkspaceReloadThatDropsARecordWithdrawsTheClaim(t *testing.T) {
	root := liveTrackerTwoRepo(t)
	s := openLive(t, root, true)
	if next := call[nextPayload](t, s, "next", nil); !next.Actionable {
		t.Fatalf("the clean workspace claims nothing: %+v", next)
	}

	web := filepath.Join(root, "web", ".beads", "issues.jsonl")
	file, err := os.OpenFile(web, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString("{not json\n"); err != nil {
		t.Fatal(err)
	}
	file.Close()
	if _, err := s.Call("reload", nil); err != nil {
		t.Fatal(err)
	}

	if next := call[nextPayload](t, s, "next", nil); next.Actionable || next.ClaimCommand != "" {
		t.Errorf("the reload kept the claim: %+v", next)
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
