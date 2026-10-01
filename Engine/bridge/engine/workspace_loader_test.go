package engine

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	"github.com/Dicklesworthstone/beads_viewer/pkg/workspace"
)

// writeWorkspace lays out repositories (path -> JSONL) and a workspace
// configuration under a fresh root.
func writeWorkspace(t *testing.T, config string, repos map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for path, content := range repos {
		dir := filepath.Join(root, path, ".beads")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "issues.jsonl"), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(root, ".bv"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".bv", "workspace.yaml"), []byte(config), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

// loadedWorkspace is one loader's output, with errors as strings so two
// loaders' wrapped errors compare by what they say.
type loadedWorkspace struct {
	Issues  []model.Issue
	Results []workspace.LoadResult
	Errors  []string
	Err     string
}

func normalise(issues []model.Issue, results []workspace.LoadResult, err error) loadedWorkspace {
	out := loadedWorkspace{Issues: issues}
	if err != nil {
		out.Err = err.Error()
	}
	for _, result := range results {
		if result.Error != nil {
			out.Errors = append(out.Errors, fmt.Sprintf("%s: %v", result.RepoName, result.Error))
			result.Error = nil
		}
		out.Results = append(out.Results, result)
	}
	return out
}

// vbx's workspace loader is a port of bv's, differing only in who decides
// whether a tracker is reached. Given bv's choices — live origins and a
// refreshed Dolt export — it must produce exactly what bv's does, origins
// included, on every shape a workspace takes. An upgrade of bv that changes
// its loader fails here instead of drifting silently.
func TestWorkspaceLoaderMatchesBV(t *testing.T) {
	const api = `{"id":"1","title":"API endpoint","status":"open","issue_type":"task","priority":1,"dependencies":[{"issue_id":"1","depends_on_id":"web-1","type":"blocks"},{"issue_id":"1","depends_on_id":"3","type":"blocks"}],"comments":[{"id":1,"issue_id":"1","author":"a","text":"hi","created_at":"2026-01-01T00:00:00Z"}]}
{"id":"2","title":"API docs","status":"open","issue_type":"docs","priority":2,"dependencies":[{"issue_id":"2","depends_on_id":"9","type":"blocks"}]}
{"id":"3","title":"Gone","status":"tombstone","issue_type":"task","priority":2}
{not json
`
	const web = `{"id":"1","title":"Web form","status":"open","issue_type":"task","priority":0}
`
	cases := map[string]func(t *testing.T) string{
		"configured, with a disabled and a tombstone": func(t *testing.T) string {
			return writeWorkspace(t, `repos:
  - {name: api, path: api, prefix: "api-"}
  - {name: web, path: web, prefix: "web-"}
  - {name: old, path: old, prefix: "old-", enabled: false}
`, map[string]string{"api": api, "web": web, "old": web})
		},
		"discovered": func(t *testing.T) string {
			return writeWorkspace(t, `discovery:
  enabled: true
`, map[string]string{"services/api": api, "web": web, "node_modules/dep": web})
		},
		"a repository that fails": func(t *testing.T) string {
			return writeWorkspace(t, `repos:
  - {name: api, path: api, prefix: "api-"}
  - {name: gone, path: gone, prefix: "gone-"}
`, map[string]string{"api": api})
		},
		"every repository fails": func(t *testing.T) string {
			return writeWorkspace(t, `repos:
  - {name: gone, path: gone, prefix: "gone-"}
`, nil)
		},
		"duplicate prefixes": func(t *testing.T) string {
			return writeWorkspace(t, `repos:
  - {name: a, path: a, prefix: "x-"}
  - {name: b, path: b, prefix: "X-"}
`, map[string]string{"a": web, "b": web})
		},
		"live trackers, br and Dolt": func(t *testing.T) string {
			root, _ := liveTrackerMultiRepo(t)
			return root
		},
	}

	live := workspaceReader{attach: attachLiveOrigins, refreshBDExport: true}
	for name, build := range cases {
		t.Run(name, func(t *testing.T) {
			// Each loader mutates what it reads only in memory, so both read
			// the same files.
			root := build(t)
			configPath := filepath.Join(root, ".bv", "workspace.yaml")

			config, err := workspace.LoadConfig(configPath)
			if err != nil {
				// bv's configuration validation is shared, not ported.
				_, _, got := loadAllFromConfig(configPath, live)
				if got == nil || got.Error() != "failed to load workspace config: "+err.Error() {
					t.Errorf("bv rejects the config with %v; vbx with %v", err, got)
				}
				return
			}
			bvLoader := workspace.NewAggregateLoader(config, root)
			bvLoader.SetLogger(nil) // vbx's port is always silent
			want := normalise(bvLoader.LoadAll(context.Background()))
			got := normalise(loadAllFromConfig(configPath, live))

			if !reflect.DeepEqual(got, want) {
				t.Errorf("vbx's loader differs from bv's\n got: %+v\nwant: %+v", got, want)
			}
			if want.Err == "" && len(want.Issues) < 2 {
				t.Errorf("bv loaded %d beads; the case proves nothing", len(want.Issues))
			}
		})
	}
}

// The comparison above is only as good as its fixtures: the live case must
// actually reach bv's tracker binding, or both loaders would agree on nothing.
func TestWorkspaceLoaderLiveCaseBindsATracker(t *testing.T) {
	root, _ := liveTrackerMultiRepo(t)
	live := workspaceReader{attach: attachLiveOrigins, refreshBDExport: true}
	issues, _, err := loadAllFromConfig(filepath.Join(root, ".bv", "workspace.yaml"), live)
	if err != nil {
		t.Fatal(err)
	}
	trackers := map[string]bool{}
	for _, issue := range issues {
		if issue.Origin != nil {
			trackers[issue.Origin.Tracker] = true
		}
	}
	if !trackers["br"] {
		t.Errorf("trackers bound: %v", trackers)
	}
}

// The app's reader binds each bead under its local id, before namespacing —
// where bv binds — so the origin names the bead as its own tracker knows it.
func TestTheAppsWorkspaceOriginsCarryLocalIDs(t *testing.T) {
	root := multiRepoWorkspace(t)
	app := (&Session{}).workspaceReader()
	issues, _, err := loadAllFromConfig(filepath.Join(root, ".bv", "workspace.yaml"), app)
	if err != nil {
		t.Fatal(err)
	}
	if len(issues) != 3 {
		t.Fatalf("loaded %d beads", len(issues))
	}
	for _, issue := range issues {
		if issue.Origin == nil || issue.Origin.ReadOnlyReason != appActionsUnavailable {
			t.Errorf("%s: origin is %+v", issue.ID, issue.Origin)
			continue
		}
		if issue.Origin.LocalID == issue.ID || workspace.QualifyID(issue.Origin.LocalID, issue.ID[:4]) != issue.ID {
			t.Errorf("%s: local id is %q", issue.ID, issue.Origin.LocalID)
		}
	}
}
