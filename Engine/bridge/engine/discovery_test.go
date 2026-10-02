package engine

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// Workspace discovery follows bv 0.25.2's precedence (vbx-1y5, ADR-026): a
// reachable `.beads` wins, a `.bv/workspace.yaml` here or above is used only
// without one, and an explicit configuration wins over both. vbx used to take
// any workspace configuration it found first, so a repository with its own
// `.beads` under (or containing) a workspace opened as the aggregate in vbx and
// as the single repository in bv — namespaced ids, a different graph and every
// number downstream of it.

// openedKind opens path the way the app and vbx-cli's --path do, and reports
// the session's kind and bead count. It checks Probe agrees, because the Open
// panel answers from Probe and must offer exactly what opens.
func openedKind(t *testing.T, cfg OpenConfig) (string, int) {
	t.Helper()
	cfg.SkipPhase2 = true
	s, err := Open(cfg)
	if err != nil {
		t.Fatalf("Open(%+v): %v", cfg, err)
	}
	defer s.Close()
	info := call[struct {
		Kind       string `json:"kind"`
		IssueCount int    `json:"issue_count"`
	}](t, s, "info", nil)

	if cfg.Workspace == "" {
		probe := Probe(cfg.Path)
		if !probe.CanOpen || probe.Kind != info.Kind {
			t.Errorf("Probe(%s) = %+v, but Open loaded a %s", cfg.Path, probe, info.Kind)
		}
	}
	return info.Kind, info.IssueCount
}

// withRootBeads gives a workspace root a `.beads` of its own, holding the
// five-bead fixture: the layout where the two precedences part.
func withRootBeads(t *testing.T, root string) {
	t.Helper()
	beads := filepath.Join(root, ".beads")
	if err := os.MkdirAll(beads, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(beads, "issues.jsonl"), []byte(fixture), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestDiscoveryBeadsOnlyIsASingleRepository(t *testing.T) {
	kind, count := openedKind(t, OpenConfig{Path: newFixtureWorkspace(t)})
	if kind != "jsonl" || count != 5 {
		t.Errorf("opened a %s of %d beads, want the jsonl of 5", kind, count)
	}
}

func TestDiscoveryWorkspaceOnlyIsTheAggregate(t *testing.T) {
	kind, count := openedKind(t, OpenConfig{Path: multiRepoWorkspace(t)})
	if kind != "workspace" || count != 3 {
		t.Errorf("opened a %s of %d beads, want the workspace of 3", kind, count)
	}
}

// Both in the one directory: bv takes the `.beads`, and so must vbx.
func TestDiscoveryPrefersTheBeadsBesideAWorkspaceConfig(t *testing.T) {
	root := multiRepoWorkspace(t)
	withRootBeads(t, root)

	kind, count := openedKind(t, OpenConfig{Path: root})
	if kind != "jsonl" || count != 5 {
		t.Errorf("opened a %s of %d beads, want the root's own jsonl of 5", kind, count)
	}
}

// A member repository below the workspace root keeps its own view: its
// `.beads` is reachable, and the configuration above it is not consulted.
func TestDiscoveryPrefersTheBeadsInTheDirectoryOverAWorkspaceAbove(t *testing.T) {
	root := multiRepoWorkspace(t)

	kind, count := openedKind(t, OpenConfig{Path: filepath.Join(root, "api")})
	if kind != "jsonl" || count != 2 {
		t.Errorf("opened a %s of %d beads, want api's own jsonl of 2", kind, count)
	}
}

// With no `.beads` reachable, the configuration is found by climbing, as
// bv's FindWorkspaceConfig climbs.
func TestDiscoveryClimbsToAWorkspaceWhenNoBeadsIsReachable(t *testing.T) {
	root := multiRepoWorkspace(t)
	notes := filepath.Join(root, "notes", "deep")
	if err := os.MkdirAll(notes, 0o755); err != nil {
		t.Fatal(err)
	}

	kind, count := openedKind(t, OpenConfig{Path: notes})
	if kind != "workspace" || count != 3 {
		t.Errorf("opened a %s of %d beads, want the workspace of 3", kind, count)
	}
}

// Reachable includes the root of the checkout a folder sits in: a subfolder of
// a repository holding `.beads` is that repository, even under a workspace.
func TestDiscoveryPrefersTheCheckoutRootsBeadsOverAWorkspaceAbove(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	root := multiRepoWorkspace(t)
	repo := filepath.Join(root, "api")
	if out, err := exec.Command("git", "init", "-q", repo).CombinedOutput(); err != nil {
		t.Fatalf("git init: %v\n%s", err, out)
	}
	sub := filepath.Join(repo, "src")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}

	kind, count := openedKind(t, OpenConfig{Path: sub})
	if kind != "jsonl" || count != 2 {
		t.Errorf("opened a %s of %d beads, want api's own jsonl of 2", kind, count)
	}
}

// BEADS_DIR makes a `.beads` reachable from anywhere, as it does for bv.
func TestDiscoveryHonoursBeadsDirOverAWorkspace(t *testing.T) {
	root := multiRepoWorkspace(t)
	t.Setenv("BEADS_DIR", filepath.Join(newFixtureWorkspace(t), ".beads"))

	kind, count := openedKind(t, OpenConfig{Path: root})
	if kind != "jsonl" || count != 5 {
		t.Errorf("opened a %s of %d beads, want BEADS_DIR's jsonl of 5", kind, count)
	}
}

// vbx-cli's --workspace: the configuration as given, with no discovery — so
// it wins over the `.beads` that discovery would have taken.
func TestExplicitWorkspaceWinsOverTheBeadsDiscoveryWouldTake(t *testing.T) {
	root := multiRepoWorkspace(t)
	withRootBeads(t, root)

	kind, count := openedKind(t, OpenConfig{
		Path: root, Workspace: filepath.Join(root, ".bv", "workspace.yaml"),
	})
	if kind != "workspace" || count != 3 {
		t.Errorf("opened a %s of %d beads, want the workspace of 3", kind, count)
	}
}

// bv's --workspace reads the file it is given and fails when it cannot; a
// missing one must not fall back to discovery.
func TestExplicitWorkspaceThatDoesNotExistFails(t *testing.T) {
	root := newFixtureWorkspace(t)
	s, err := Open(OpenConfig{
		Path: root, Workspace: filepath.Join(root, ".bv", "workspace.yaml"), SkipPhase2: true,
	})
	if s != nil {
		s.Close()
	}
	if err == nil {
		t.Error("opened a workspace configuration that does not exist")
	}
}

// The app's way to the aggregate of a folder that also holds a `.beads`:
// choose the configuration file itself.
func TestChoosingTheWorkspaceConfigFileOpensTheAggregate(t *testing.T) {
	root := multiRepoWorkspace(t)
	withRootBeads(t, root)

	kind, count := openedKind(t, OpenConfig{Path: filepath.Join(root, ".bv", "workspace.yaml")})
	if kind != "workspace" || count != 3 {
		t.Errorf("opened a %s of %d beads, want the workspace of 3", kind, count)
	}
}

// A `.beads` chosen directly is that repository, even under a workspace.
func TestChoosingABeadsDirectoryUnderAWorkspaceOpensThatRepository(t *testing.T) {
	root := multiRepoWorkspace(t)

	kind, count := openedKind(t, OpenConfig{Path: filepath.Join(root, "web", ".beads")})
	if kind != "jsonl" || count != 1 {
		t.Errorf("opened a %s of %d beads, want web's own jsonl of 1", kind, count)
	}
}

// The panel greys out a YAML file that is not a workspace configuration
// rather than offering what the loader then refuses.
func TestProbeRefusesAYAMLFileThatIsNotAWorkspace(t *testing.T) {
	path := filepath.Join(t.TempDir(), "recipes.yaml")
	if err := os.WriteFile(path, []byte("recipes:\n  a: {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	result := Probe(path)
	if result.CanOpen {
		t.Fatalf("offered a YAML file that is not a workspace: %+v", result)
	}
	if result.Reason == "" {
		t.Error("refused without saying why")
	}
	s, err := Open(OpenConfig{Path: path, SkipPhase2: true})
	if s != nil {
		s.Close()
	}
	if err == nil {
		t.Error("Open accepted what Probe refused")
	}
}
