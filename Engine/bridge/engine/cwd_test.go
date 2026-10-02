package engine

import (
	"os"
	"path/filepath"
	"testing"
)

// vbx-9g1: an empty Path is the working directory as bv's os.Getwd spells it,
// which keeps $PWD's spelling when it names the same directory — the symlink
// a shell cd'd through, not the target getcwd resolves it to. vbx-cli used to
// pass FileManager's currentDirectoryPath, which is getcwd, so on macOS every
// path it printed from the working directory read /private/var/… where bv's
// read /var/…. It now passes an empty Path, and these lock in the engine's
// half: the spelling survives to source_path and to the discovered workspace
// configuration the discovery notice names.

// enterThroughLink makes a symlink to dir and makes it the working directory
// with $PWD spelled through it, as a shell's cd does. Returns the link.
func enterThroughLink(t *testing.T, dir string) string {
	t.Helper()
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(dir, link); err != nil {
		t.Fatal(err)
	}
	t.Chdir(link)
	t.Setenv("PWD", link)
	resolved, err := filepath.EvalSymlinks(link)
	if err != nil {
		t.Fatal(err)
	}
	if resolved == link {
		t.Fatalf("%s does not go through a symlink, so the test proves nothing", link)
	}
	return link
}

func TestEmptyPathKeepsPWDsSpellingOfTheSource(t *testing.T) {
	link := enterThroughLink(t, newFixtureWorkspace(t))

	src, kind, _, _, err := resolveSource("")
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(link, ".beads", "issues.jsonl"); src != want || kind != "jsonl" {
		t.Errorf("resolveSource(\"\") = %s (%s), want %s (jsonl)", src, kind, want)
	}
}

func TestEmptyPathKeepsPWDsSpellingOfTheWorkspaceConfig(t *testing.T) {
	link := enterThroughLink(t, multiRepoWorkspace(t))

	if got, want := discoverWorkspaceConfig(""), filepath.Join(link, ".bv", "workspace.yaml"); got != want {
		t.Errorf("discoverWorkspaceConfig(\"\") = %q, want %q", got, want)
	}
}
