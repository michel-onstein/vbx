package engine

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// TestWorkspaceTombstoneResolvesItsDependents: bv's workspace loader drops a
// tombstone's record and reports its namespaced id instead. Without that id
// in the readiness authority, a bead blocked only by the deleted one waits on
// a missing blocker — "unknown" to bv's ReadinessIndex — and is withheld.
func TestWorkspaceTombstoneResolvesItsDependents(t *testing.T) {
	root := multiRepoWorkspace(t)
	web := filepath.Join(root, "web", ".beads", "issues.jsonl")
	content := `{"id":"1","title":"Web form","status":"open","issue_type":"task","priority":0}
{"id":"2","title":"Deleted","status":"tombstone","issue_type":"task","priority":2}
`
	if err := os.WriteFile(web, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	api := filepath.Join(root, "api", ".beads", "issues.jsonl")
	content = `{"id":"1","title":"API endpoint","status":"open","issue_type":"task","priority":1,"dependencies":[{"issue_id":"1","depends_on_id":"web-2","type":"blocks"}]}
`
	if err := os.WriteFile(api, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	s, err := Open(OpenConfig{Path: root, SkipPhase2: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	if got := actionableIDs(t, s); !slices.Contains(got, "api-1") {
		t.Errorf("actionable = %v; api-1's only blocker is the tombstone web-2", got)
	}
	if got := recipeIDs(t, s, "actionable"); !slices.Contains(got, "api-1") {
		t.Errorf("actionable recipe = %v; api-1's only blocker is the tombstone web-2", got)
	}
}

// TestReloadSeesAChangeConfinedToATombstone: the reload gate hashes every
// record. Gating on the analysis set's hash would ignore an edit to a
// tombstone, and the issues payload would keep serving the old record.
func TestReloadSeesAChangeConfinedToATombstone(t *testing.T) {
	dir := t.TempDir()
	beads := filepath.Join(dir, ".beads")
	if err := os.MkdirAll(beads, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(beads, "issues.jsonl")
	record := `{"id":"t-1","title":"Live","status":"open","issue_type":"task","priority":1}
{"id":"t-2","title":"Deleted","status":"tombstone","issue_type":"task","priority":2}
`
	if err := os.WriteFile(path, []byte(record), 0o644); err != nil {
		t.Fatal(err)
	}
	s, err := Open(OpenConfig{Path: dir, SkipPhase2: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	edited := strings.Replace(record, `"Deleted"`, `"Deleted, renamed"`, 1)
	if err := os.WriteFile(path, []byte(edited), 0o644); err != nil {
		t.Fatal(err)
	}
	got := call[struct {
		Changed bool `json:"changed"`
	}](t, s, "reload", nil)
	if !got.Changed {
		t.Error("reload reported no change after a tombstone's record changed")
	}
	for _, issue := range s.recordSet() {
		if issue.ID == "t-2" && issue.Title != "Deleted, renamed" {
			t.Errorf("t-2 still reads %q after reload", issue.Title)
		}
	}
}
