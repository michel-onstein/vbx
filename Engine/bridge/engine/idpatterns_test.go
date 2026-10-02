package engine

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"

	"github.com/qjam/vbx/engine/correlation"
)

// brIDRepo builds a repository whose beads carry br-minted ids — a base36
// token, no numeric suffix — and a commit by another author that names one
// in its message without touching the beads file. bv's built-in patterns
// cannot see that id, so only a registered pattern links the commit (vbx-znj).
func brIDRepo(t *testing.T, issuePrefix string) string {
	t.Helper()
	b := newRepo(t)
	if issuePrefix != "" {
		b.write(".beads/config.yaml", "issue_prefix: "+issuePrefix+"\n")
	}
	b.write(".beads/issues.jsonl",
		bead("proj-8ou", "Profile the cache", "open")+"\n"+
			bead("proj-k7j", "Split the loader", "open")+"\n")
	b.commit("Add initial beads", "ada")

	b.write("src/cache.go", "package src\n\nvar Size = 64\n")
	b.commit("Grow the cache for proj-8ou", "grace")

	b.write("src/other.go", "package src\n\nvar Y = 2\n")
	b.commit("Mention proj-cli, which is no bead", "grace")
	return b.dir
}

func openWith(t *testing.T, cfg OpenConfig) *Session {
	t.Helper()
	cfg.SkipPhase2 = true
	s, err := Open(cfg)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)
	return s
}

// linkedBy reports the methods linking the commit with the message to the
// bead, or nil when it is not linked.
func linkedBy(report historyPayloadShape, beadID, message string) []string {
	for _, commit := range report.Histories[beadID].Commits {
		if commit.Message == message {
			return commit.Methods
		}
	}
	return nil
}

const brMessage = "Grow the cache for proj-8ou"

func TestBRIDIsNotLinkedWithoutAPattern(t *testing.T) {
	s := openWith(t, OpenConfig{Path: brIDRepo(t, "proj")})
	report := call[historyPayloadShape](t, s, "history", nil)
	if got := linkedBy(report, "proj-8ou", brMessage); got != nil {
		t.Errorf("bv's built-in patterns linked a br id by %v; the default is bv's, which needs a numeric suffix", got)
	}
}

// bv's --id-pattern: the CLI's flag, carried in OpenConfig.
func TestIDPatternLinksABRID(t *testing.T) {
	s := openWith(t, OpenConfig{Path: brIDRepo(t, ""), IDPatterns: []string{`proj-[a-z0-9]{3}`}})
	report := call[historyPayloadShape](t, s, "history", nil)
	if got := linkedBy(report, "proj-8ou", brMessage); !hasValue(got, "explicit_id") {
		t.Errorf("the commit naming proj-8ou is linked by %v, want explicit_id", got)
	}

	orphans := call[struct {
		Candidates []struct {
			Message string `json:"message"`
		} `json:"candidates"`
	}](t, s, "orphans", map[string]any{"orphans_min_score": 0})
	for _, c := range orphans.Candidates {
		if c.Message == brMessage {
			t.Errorf("a commit the pattern links is still an orphan candidate")
		}
	}
}

// The app's default: one pattern per id prefix, from .beads/config.yaml.
func TestPrefixDefaultLinksABRID(t *testing.T) {
	s := openWith(t, OpenConfig{Path: brIDRepo(t, "proj"), IDPatternsFromPrefix: true})
	report := call[historyPayloadShape](t, s, "history", nil)
	if got := linkedBy(report, "proj-8ou", brMessage); !hasValue(got, "explicit_id") {
		t.Errorf("the commit naming proj-8ou is linked by %v, want explicit_id", got)
	}
	// A word shaped like an id links nothing, because no bead carries it.
	if _, ok := report.Histories["proj-cli"]; ok {
		t.Error("proj-cli, which is no bead, has a history")
	}
}

func TestPrefixDefaultWithoutAPrefixRegistersNothing(t *testing.T) {
	s := openWith(t, OpenConfig{Path: brIDRepo(t, ""), IDPatternsFromPrefix: true})
	if raw, _ := s.historyIDPatterns(); len(raw) != 0 {
		t.Errorf("patterns %q with no issue_prefix configured, want none", raw)
	}
}

func TestPrefixPatternShape(t *testing.T) {
	re := regexp.MustCompile(prefixIDPattern("vbx"))
	for text, want := range map[string]string{
		"Fix vbx-8ou properly": "vbx-8ou",
		"see (vbx-q1rfj.2)":    "vbx-q1rfj.2",
		"Closes vbx-znj.":      "vbx-znj",
		"myvbx-8ou is not one": "",
		"a.b+c-8ou is not one": "",
		"VBX-8OU is not br's":  "",
	} {
		got := ""
		if m := re.FindStringSubmatch(text); m != nil {
			got = m[1]
		}
		if got != want {
			t.Errorf("%q: matched %q, want %q", text, got, want)
		}
	}
	if !strings.Contains(prefixIDPattern("a.b"), `a\.b-`) {
		t.Error("the prefix is not quoted")
	}
}

func TestWorkspacePrefixesAreEachMembers(t *testing.T) {
	s := openWith(t, OpenConfig{Path: multiRepoWorkspace(t), IDPatternsFromPrefix: true})
	if got := strings.Join(s.idPrefixes(), ","); got != "api,web" {
		t.Errorf("prefixes %q, want api,web", got)
	}
}

// bv's text for a pattern that does not compile, before anything is read:
// the path does not even exist.
func TestInvalidIDPatternIsBVsError(t *testing.T) {
	_, err := Open(OpenConfig{Path: filepath.Join(t.TempDir(), "missing"), IDPatterns: []string{`ok-\d+`, `(`}})
	want := "Invalid --id-pattern \"(\": error parsing regexp: missing closing ): `(`"
	if err == nil || err.Error() != want {
		t.Errorf("error %v, want %q", err, want)
	}
}

// The package global is registered only for the use and put back, so one
// session's patterns never leak into another's report.
func TestIDPatternsDoNotLeakBetweenSessions(t *testing.T) {
	dir := brIDRepo(t, "proj")
	with := openWith(t, OpenConfig{Path: dir, IDPatterns: []string{`proj-[a-z0-9]{3}`}})
	without := openWith(t, OpenConfig{Path: dir})

	var wg sync.WaitGroup
	reports := make([]historyPayloadShape, 2)
	for i, s := range []*Session{with, without} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			reports[i] = call[historyPayloadShape](t, s, "history", nil)
		}()
	}
	wg.Wait()
	if got := linkedBy(reports[0], "proj-8ou", brMessage); !hasValue(got, "explicit_id") {
		t.Errorf("the session with the pattern links by %v", got)
	}
	if got := linkedBy(reports[1], "proj-8ou", brMessage); got != nil {
		t.Errorf("the session without one links by %v", got)
	}
	if left := correlation.CustomIDPatterns(); len(left) != 0 {
		t.Errorf("patterns left registered: %v", left)
	}
}

// Editing config.yaml's prefix is picked up by the next request: the
// patterns key the extraction cache.
func TestPrefixChangeReachesTheNextReport(t *testing.T) {
	dir := brIDRepo(t, "other")
	s := openWith(t, OpenConfig{Path: dir, IDPatternsFromPrefix: true})
	if got := linkedBy(call[historyPayloadShape](t, s, "history", nil), "proj-8ou", brMessage); got != nil {
		t.Fatalf("linked by %v under another prefix", got)
	}
	if err := os.WriteFile(filepath.Join(dir, ".beads", "config.yaml"), []byte("issue_prefix: proj\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := linkedBy(call[historyPayloadShape](t, s, "history", nil), "proj-8ou", brMessage); !hasValue(got, "explicit_id") {
		t.Errorf("after the prefix changed, linked by %v", got)
	}
}
