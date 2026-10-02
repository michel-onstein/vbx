package engine

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/object"
)

// The history tests run against a real repository built here with go-git —
// no git binary is involved in building it or in reading it back. That the
// reports equal bv's own, byte for byte, is proven in the correlation
// package's differential tests and by the parity harness; these tests pin
// down vbx's side: the handlers, the scope, the cache and the feedback.

type repoBuilder struct {
	t    *testing.T
	dir  string
	repo *git.Repository
	tree *git.Worktree
	when time.Time
}

func newRepo(t *testing.T) *repoBuilder {
	t.Helper()
	dir := t.TempDir()
	repo, err := git.PlainInit(dir, false)
	if err != nil {
		t.Fatalf("init: %v", err)
	}
	tree, err := repo.Worktree()
	if err != nil {
		t.Fatalf("worktree: %v", err)
	}
	return &repoBuilder{
		t:    t,
		dir:  dir,
		repo: repo,
		tree: tree,
		when: time.Date(2026, 1, 1, 9, 0, 0, 0, time.UTC),
	}
}

// write puts a file in the working tree, creating parents.
func (b *repoBuilder) write(rel, content string) {
	b.t.Helper()
	full := filepath.Join(b.dir, rel)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		b.t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		b.t.Fatal(err)
	}
	if _, err := b.tree.Add(rel); err != nil {
		b.t.Fatalf("add %s: %v", rel, err)
	}
}

// commit records the staged files. Each commit advances the clock an hour, so
// the history has a real ordering to reason about.
func (b *repoBuilder) commit(message, author string) string {
	b.t.Helper()
	b.when = b.when.Add(time.Hour)
	sig := &object.Signature{Name: author, Email: author + "@example.com", When: b.when}
	hash, err := b.tree.Commit(message, &git.CommitOptions{Author: sig, Committer: sig})
	if err != nil {
		b.t.Fatalf("commit %q: %v", message, err)
	}
	return hash.String()
}

// bead renders one JSONL record.
func bead(id, title, status string) string {
	return labelledBead(id, title, status, "core")
}

func labelledBead(id, title, status, label string) string {
	return `{"id":"` + id + `","title":"` + title + `","status":"` + status +
		`","issue_type":"task","priority":1,"created_at":"2026-01-01T00:00:00Z",` +
		`"updated_at":"2026-01-02T00:00:00Z","labels":["` + label + `"]}`
}

// historyRepo builds a repository whose history exercises every strategy: a
// bead claimed alongside code (co-committed), a commit naming it (explicit
// id), a commit belonging to no bead, and a bookkeeping-only close.
func historyRepo(t *testing.T) string {
	t.Helper()
	b := newRepo(t)

	b.write(".beads/issues.jsonl",
		bead("proj-1", "Rewrite the loader", "open")+"\n"+
			labelledBead("proj-2", "Polish the docs", "open", "docs")+"\n")
	b.commit("Add initial beads", "ada")

	b.write(".beads/issues.jsonl",
		bead("proj-1", "Rewrite the loader", "in_progress")+"\n"+
			labelledBead("proj-2", "Polish the docs", "open", "docs")+"\n")
	b.write("src/loader.go", "package src\n\nfunc Load() {}\n")
	b.commit("Start the loader rewrite", "ada")

	b.write("src/loader.go", "package src\n\nfunc Load() error { return nil }\n")
	b.commit("Closes proj-1: loader returns an error", "ada")

	b.write("src/unrelated.go", "package src\n\nvar X = 1\n")
	b.commit("Tweak an unrelated helper", "grace")

	b.write(".beads/issues.jsonl",
		bead("proj-1", "Rewrite the loader", "closed")+"\n"+
			labelledBead("proj-2", "Polish the docs", "open", "docs")+"\n")
	b.commit("Mark the loader rewrite done", "ada")

	return b.dir
}

func openHistorySession(t *testing.T) *Session {
	t.Helper()
	s, err := Open(OpenConfig{Path: historyRepo(t), SkipPhase2: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)
	return s
}

type historyPayloadShape struct {
	GitRange  string `json:"git_range"`
	DataHash  string `json:"data_hash"`
	ScopeHash string `json:"scope_hash"`
	Scope     *struct {
		Label string `json:"label"`
	} `json:"scope"`
	LatestCommitSHA string `json:"latest_commit_sha"`
	Window          struct {
		Limit   int `json:"limit"`
		Commits int `json:"commits"`
	} `json:"window"`
	CommitIndex map[string][]string `json:"commit_index"`
	Stats       struct {
		TotalBeads         int            `json:"total_beads"`
		BeadsWithCommits   int            `json:"beads_with_commits"`
		TotalCommits       int            `json:"total_commits"`
		UniqueAuthors      int            `json:"unique_authors"`
		MethodDistribution map[string]int `json:"method_distribution"`
		Strategies         []struct {
			Name string `json:"name"`
			Ran  bool   `json:"ran"`
		} `json:"strategies"`
	} `json:"stats"`
	Histories map[string]struct {
		BeadID string `json:"bead_id"`
		Title  string `json:"title"`
		Status string `json:"status"`
		Events []struct {
			EventType string `json:"event_type"`
			CommitSHA string `json:"commit_sha"`
			Before    *struct {
				Status string `json:"status"`
			} `json:"before"`
			After *struct {
				Status string `json:"status"`
			} `json:"after"`
			TransitionObserved bool `json:"transition_observed"`
		} `json:"events"`
		Commits []struct {
			SHA        string   `json:"sha"`
			ShortSHA   string   `json:"short_sha"`
			Message    string   `json:"message"`
			Method     string   `json:"method"`
			Methods    []string `json:"methods"`
			Confidence float64  `json:"confidence"`
			Confirmed  bool     `json:"confirmed"`
			Files      []struct {
				Path       string `json:"path"`
				Insertions int    `json:"insertions"`
			} `json:"files"`
		} `json:"commits"`
	} `json:"histories"`
}

// The report reads the object store: with no git anywhere on PATH, it still
// walks every commit and reads every beads blob.
func TestHistoryNeedsNoGitBinary(t *testing.T) {
	s := openHistorySession(t)
	t.Setenv("PATH", "")

	report := call[historyPayloadShape](t, s, "history", nil)
	if report.Window.Commits != 5 || report.Window.Limit != 500 {
		t.Errorf("window %+v, want 5 commits walked under bv's default limit of 500", report.Window)
	}
	if report.GitRange != "limit 500 commits" {
		t.Errorf("git_range %q, want bv's description of the walk", report.GitRange)
	}
	if len(report.DataHash) != 12 {
		t.Errorf("data_hash %q is not the correlator's short hash of the beads", report.DataHash)
	}
	if report.ScopeHash == "" || report.Scope != nil {
		t.Errorf("an unscoped report carries scope_hash and no scope; got %q, %+v",
			report.ScopeHash, report.Scope)
	}

	one, ok := report.Histories["proj-1"]
	if !ok {
		t.Fatalf("no history for proj-1, got %v", keysOf(report.Histories))
	}
	var events []string
	for _, e := range one.Events {
		events = append(events, e.EventType)
		if !e.TransitionObserved || e.After == nil {
			t.Errorf("%s event carries no observed after-state", e.EventType)
		}
	}
	if strings.Join(events, ",") != "created,claimed,closed" {
		t.Fatalf("events %v, want created, claimed, closed", events)
	}
	if claimed := one.Events[1]; claimed.Before == nil || claimed.Before.Status != "open" ||
		claimed.After.Status != "in_progress" {
		t.Errorf("the claim does not record open -> in_progress: %+v", claimed)
	}
}

// Each commit is linked by the strategies bv runs, and says which.
func TestHistoryLinksCommitsByBVsStrategies(t *testing.T) {
	s := openHistorySession(t)
	report := call[historyPayloadShape](t, s, "history", nil)

	methods := map[string][]string{}
	for _, commit := range report.Histories["proj-1"].Commits {
		methods[commit.Message] = commit.Methods
		for _, file := range commit.Files {
			if strings.HasPrefix(file.Path, ".beads/") {
				t.Errorf("%s attributes bookkeeping as code: %s", commit.ShortSHA, file.Path)
			}
		}
	}
	if got := methods["Start the loader rewrite"]; len(got) == 0 || got[0] != "co_committed" {
		t.Errorf("the claim commit is linked by %v, want co_committed", got)
	}
	if got := methods["Closes proj-1: loader returns an error"]; !hasValue(got, "explicit_id") {
		t.Errorf("the commit naming proj-1 is linked by %v, want explicit_id among them", got)
	}
	if _, ok := methods["Tweak an unrelated helper"]; ok {
		t.Error("grace's unrelated commit was linked to proj-1")
	}
	var ran []string
	for _, run := range report.Stats.Strategies {
		if run.Ran {
			ran = append(ran, run.Name)
		}
	}
	if strings.Join(ran, ",") != "co_committed,explicit_id,temporal_author" {
		t.Errorf("strategies run: %v", ran)
	}
}

func hasValue(values []string, want string) bool {
	for _, v := range values {
		if v == want {
			return true
		}
	}
	return false
}

func TestHistoryForOneBead(t *testing.T) {
	s := openHistorySession(t)
	report := call[historyPayloadShape](t, s, "history", map[string]any{"id": "proj-1"})
	if len(report.Histories) != 1 || report.Histories["proj-1"].Title != "Rewrite the loader" {
		t.Errorf("--bead-history proj-1 returned %v", keysOf(report.Histories))
	}
}

// --history-limit bounds the walk, and the report says so.
func TestHistoryLimitBoundsTheWalk(t *testing.T) {
	s := openHistorySession(t)
	report := call[historyPayloadShape](t, s, "history", map[string]any{"history_limit": 2})
	if report.Window.Commits != 2 || report.GitRange != "limit 2 commits" {
		t.Errorf("window %+v, range %q; want two commits", report.Window, report.GitRange)
	}
	all := call[historyPayloadShape](t, s, "history", map[string]any{"history_limit": 0})
	if all.GitRange != "all history" || all.Window.Commits != 5 {
		t.Errorf("history_limit 0 walked %d commits as %q, want all history",
			all.Window.Commits, all.GitRange)
	}
}

// A scope narrows the report to its beads, as bv builds it from its scoped
// issues, and the envelope says so.
func TestHistoryAnswersOverTheScope(t *testing.T) {
	s := openHistorySession(t)
	whole := call[historyPayloadShape](t, s, "history", nil)
	scoped := call[historyPayloadShape](t, s, "history", map[string]any{"label": "docs"})

	if _, ok := scoped.Histories["proj-1"]; ok || len(scoped.Histories) != 1 {
		t.Errorf("the docs scope reported %v, want proj-2 alone", keysOf(scoped.Histories))
	}
	if scoped.Stats.TotalBeads != 1 {
		t.Errorf("the docs scope counts %d beads", scoped.Stats.TotalBeads)
	}
	if scoped.Scope == nil || scoped.Scope.Label != "docs" {
		t.Errorf("the envelope does not name the scope: %+v", scoped.Scope)
	}
	if scoped.DataHash == whole.DataHash || scoped.ScopeHash == whole.ScopeHash {
		t.Error("the scoped report hashes the same beads as the whole one")
	}

	unknown := call[historyPayloadShape](t, s, "history", map[string]any{"label": "no-such-label"})
	if len(unknown.Histories) != 0 {
		t.Errorf("an unknown label reported %v", keysOf(unknown.Histories))
	}
}

func TestHistoryErrorsAreBVs(t *testing.T) {
	s := openHistorySession(t)
	for _, c := range []struct{ method, req, want string }{
		{"causality", `{"id":"nope-9"}`, "Bead not found: nope-9"},
		{"related", `{"id":"nope-9"}`, "Bead not found in history: nope-9"},
		{"impact_network", `{"id":"nope-9"}`, "Bead not found in network: nope-9"},
		{"causality", ``, "causality requires an \"id\""},
		{"file_beads", `{}`, "file_beads requires a \"path\""},
		{"file_impact", `{"files":[]}`, "file_impact requires a non-empty \"files\""},
	} {
		_, err := s.Call(c.method, []byte(c.req))
		if err == nil || err.Error() != c.want {
			t.Errorf("%s %s: error %v, want %q", c.method, c.req, err, c.want)
		}
	}
	// A bead outside the scope is not in its history either.
	if _, err := s.Call("related", []byte(`{"id":"proj-1","label":"docs"}`)); err == nil {
		t.Error("related answered for a bead outside the scope")
	}
}

type causalityShape struct {
	DataHash string `json:"data_hash"`
	Chain    struct {
		BeadID     string `json:"bead_id"`
		IsComplete bool   `json:"is_complete"`
		Events     []struct {
			Type string `json:"type"`
		} `json:"events"`
	} `json:"chain"`
}

func TestCausalityChain(t *testing.T) {
	s := openHistorySession(t)
	result := call[causalityShape](t, s, "causality", map[string]any{"id": "proj-1"})
	if result.Chain.BeadID != "proj-1" || len(result.Chain.Events) == 0 {
		t.Errorf("chain %+v", result.Chain)
	}
	if !result.Chain.IsComplete {
		t.Error("a created-and-closed bead reports an incomplete chain")
	}
	// The envelope's hash wins over the result's own, as bv's withEnvelope
	// lays it.
	history := call[historyPayloadShape](t, s, "history", nil)
	if result.DataHash != history.DataHash {
		t.Errorf("causality data_hash %q, history's %q", result.DataHash, history.DataHash)
	}
}

func TestFileCommands(t *testing.T) {
	s := openHistorySession(t)

	lookup := call[struct {
		FilePath   string `json:"file_path"`
		TotalBeads int    `json:"total_beads"`
		ScopeHash  string `json:"scope_hash"`
	}](t, s, "file_beads", map[string]any{"path": "src/loader.go"})
	if lookup.FilePath != "src/loader.go" || lookup.TotalBeads != 1 || lookup.ScopeHash == "" {
		t.Errorf("file_beads %+v", lookup)
	}

	hotspots := call[struct {
		Hotspots []struct {
			FilePath string `json:"file_path"`
		} `json:"hotspots"`
		Stats struct {
			TotalFiles int `json:"total_files"`
		} `json:"stats"`
	}](t, s, "file_hotspots", map[string]any{"hotspots_limit": 1})
	if len(hotspots.Hotspots) != 1 || hotspots.Hotspots[0].FilePath != "src/loader.go" {
		t.Errorf("hotspots %+v", hotspots.Hotspots)
	}

	relations := call[struct {
		FilePath  string  `json:"file_path"`
		Threshold float64 `json:"threshold"`
	}](t, s, "file_relations", map[string]any{"path": "src/loader.go"})
	if relations.FilePath != "src/loader.go" || relations.Threshold != 0.5 {
		t.Errorf("file_relations %+v, want bv's default threshold of 0.5", relations)
	}

	impact := call[struct {
		Files     []string `json:"files"`
		RiskLevel string   `json:"risk_level"`
	}](t, s, "file_impact", map[string]any{"files": []string{" src/loader.go "}})
	if len(impact.Files) != 1 || impact.Files[0] != "src/loader.go" || impact.RiskLevel == "" {
		t.Errorf("file_impact %+v", impact)
	}
}

func TestOrphansAreBVsDetector(t *testing.T) {
	s := openHistorySession(t)
	report := call[struct {
		Window struct {
			Source string `json:"source"`
		} `json:"window"`
		Stats struct {
			TotalCommits     int `json:"total_commits"`
			OrphanCount      int `json:"orphan_count"`
			BeadsOnlyCommits int `json:"beads_only_commits"`
		} `json:"stats"`
		UsageHints []string `json:"usage_hints"`
	}](t, s, "orphans", map[string]any{"orphans_min_score": 0})

	if report.Window.Source != "history_index" || report.Stats.TotalCommits != 3 {
		t.Errorf("orphans scanned %+v / %+v, want the history's own window: five commits, three of them code",
			report.Window, report.Stats)
	}
	// Two commits changed nothing but the beads file; grace's helper commit
	// is the one code commit no bead accounts for.
	if report.Stats.BeadsOnlyCommits != 2 || report.Stats.OrphanCount != 1 {
		t.Errorf("stats %+v, want 2 bookkeeping commits and 1 orphan", report.Stats)
	}
	if len(report.UsageHints) == 0 {
		t.Error("bv's usage hints are missing")
	}
}

func TestImpactNetworkAndRelatedWork(t *testing.T) {
	s := openHistorySession(t)
	network := call[struct {
		Network struct {
			Stats struct {
				TotalNodes int `json:"total_nodes"`
			} `json:"stats"`
		} `json:"network"`
	}](t, s, "impact_network", map[string]any{"id": "all"})
	if network.Network.Stats.TotalNodes == 0 {
		t.Error("the impact network has no nodes")
	}
	related := call[struct {
		TargetBeadID string `json:"target_bead_id"`
	}](t, s, "related", map[string]any{"id": "proj-1"})
	if related.TargetBeadID != "proj-1" {
		t.Errorf("related work targeted %q", related.TargetBeadID)
	}
}

// The extraction is cached per session: kept while nothing changes, dropped
// when the bead set reloads, and keyed by HEAD so a new commit is walked.
func TestHistoryExtractionIsCached(t *testing.T) {
	b := newRepo(t)
	b.write(".beads/issues.jsonl", bead("proj-1", "Rewrite the loader", "open")+"\n")
	b.commit("Add beads", "ada")
	s, err := Open(OpenConfig{Path: b.dir, SkipPhase2: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	cached := func() int {
		s.historyMu.Lock()
		defer s.historyMu.Unlock()
		return len(s.historyArtifacts)
	}

	call[historyPayloadShape](t, s, "history", nil)
	call[historyPayloadShape](t, s, "file_hotspots", nil)
	if cached() != 1 {
		t.Errorf("%d extractions cached for one walk, want 1", cached())
	}

	if _, err := s.Call("reload", nil); err != nil {
		t.Fatalf("reload: %v", err)
	}
	if cached() != 1 {
		t.Error("an unchanged reload threw away the cached extraction")
	}

	// A commit moves HEAD: the next report walks again and sees it.
	b.write("src/a.go", "package src\n")
	b.commit("Code for proj-1", "ada")
	report := call[historyPayloadShape](t, s, "history", nil)
	if report.Window.Commits != 2 {
		t.Errorf("after a commit the report walked %d commits, want 2", report.Window.Commits)
	}

	b.write(".beads/issues.jsonl", bead("proj-1", "Rewrite the loader", "open")+"\n"+
		bead("proj-3", "Something new", "open")+"\n")
	if _, err := s.Call("reload", nil); err != nil {
		t.Fatalf("reload after change: %v", err)
	}
	if cached() != 0 {
		t.Error("a changed reload left the cached extraction in place")
	}
	refreshed := call[historyPayloadShape](t, s, "history", nil)
	if _, ok := refreshed.Histories["proj-3"]; !ok {
		t.Error("the rebuilt report does not mention the newly added bead")
	}
}

type feedbackShape struct {
	Type         string  `json:"type"`
	OriginalConf float64 `json:"original_conf"`
	Stats        struct {
		Confirmed int `json:"confirmed"`
		Rejected  int `json:"rejected"`
	} `json:"stats"`
}

// A rejection removes the link everywhere the report derives from it; the
// verdict records the strategy's own confidence.
func TestRejectingALinkRemovesIt(t *testing.T) {
	s := openHistorySession(t)
	before := call[historyPayloadShape](t, s, "history", nil)
	target := before.Histories["proj-1"].Commits[0]

	result := call[feedbackShape](t, s, "correlation_reject",
		map[string]any{"sha": target.SHA, "bead_id": "proj-1", "reason": "wrong bead"})
	if result.Type != "reject" || result.Stats.Rejected != 1 {
		t.Errorf("verdict %+v", result)
	}
	if result.OriginalConf != target.Confidence {
		t.Errorf("recorded confidence %v, engine said %v", result.OriginalConf, target.Confidence)
	}

	after := call[historyPayloadShape](t, s, "history", nil)
	for _, commit := range after.Histories["proj-1"].Commits {
		if commit.SHA == target.SHA {
			t.Error("a rejected link is still attributed to the bead")
		}
	}
	for _, id := range after.CommitIndex[target.SHA] {
		if id == "proj-1" {
			t.Error("the commit index still points the rejected commit at proj-1")
		}
	}
}

// A confirmation pins the link at 1.0 and marks it, as bv's feedback does —
// and a later verdict still records the strategy's confidence, not the pin.
func TestConfirmingALinkPinsIt(t *testing.T) {
	s := openHistorySession(t)
	before := call[historyPayloadShape](t, s, "history", nil)
	target := before.Histories["proj-1"].Commits[0]

	call[feedbackShape](t, s, "correlation_confirm",
		map[string]any{"sha": target.SHA, "bead_id": "proj-1", "reason": "correct"})
	after := call[historyPayloadShape](t, s, "history", nil)
	for _, commit := range after.Histories["proj-1"].Commits {
		if commit.SHA == target.SHA && (commit.Confidence != 1 || !commit.Confirmed) {
			t.Errorf("confirmed link is at %v, confirmed=%v", commit.Confidence, commit.Confirmed)
		}
	}

	again := call[feedbackShape](t, s, "correlation_reject",
		map[string]any{"sha": target.SHA, "bead_id": "proj-1"})
	if again.OriginalConf != target.Confidence {
		t.Errorf("the second verdict recorded %v, want the strategy's %v",
			again.OriginalConf, target.Confidence)
	}
}

func TestFeedbackRequiresBothIdentifiers(t *testing.T) {
	s := openHistorySession(t)
	for _, req := range []string{``, `{}`, `{"sha":"abc"}`, `{"bead_id":"proj-1"}`} {
		if _, err := s.Call("correlation_confirm", []byte(req)); err == nil {
			t.Errorf("expected an error for request %q", req)
		}
	}
}

func TestHistoryOutsideARepositoryIsAnError(t *testing.T) {
	// The fixture workspace is a bare temp directory with no .git.
	s := openFixture(t)
	if _, err := s.Call("history", nil); err == nil {
		t.Error("expected an error when the workspace is not in a git repository")
	}
}

// The payload is bv's: the report's fields beside the envelope, and nothing
// of the report's own generated_at or data_hash left to disagree with it.
func TestHistoryPayloadKeysAreBVs(t *testing.T) {
	s := openHistorySession(t)
	raw, err := s.Call("history", nil)
	if err != nil {
		t.Fatal(err)
	}
	var top map[string]json.RawMessage
	if err := json.Unmarshal(raw, &top); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"generated_at", "data_hash", "output_format", "scope_hash",
		"git_range", "latest_commit_sha", "window", "stats", "histories", "commit_index"} {
		if _, ok := top[key]; !ok {
			t.Errorf("history payload has no %q", key)
		}
	}
}

func keysOf[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
