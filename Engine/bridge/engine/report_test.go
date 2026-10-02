package engine

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// reportShape is export_report's payload.
type reportShape struct {
	Content      string `json:"content"`
	Format       string `json:"format"`
	IncludeGraph bool   `json:"include_graph"`
	Template     string `json:"template"`
	Title        string `json:"title"`
	IssueCount   int    `json:"issue_count"`
	Bytes        int    `json:"bytes"`
	Path         string `json:"path"`
	LabelMatches *int   `json:"label_matches"`
}

// openReportFixture opens the five-bead fixture with a project recipe file
// whose recipes carry export defaults, as bv's `export:` block does.
func openReportFixture(t *testing.T) (*Session, string) {
	t.Helper()
	dir := newFixtureWorkspace(t)
	template := filepath.Join(dir, "report.tmpl")
	writeFile(t, template, "{{.Title}}:{{range .Issues}} {{.ID}}{{end}}|{{if .Graph}}graph{{end}}\n")
	writeFile(t, filepath.Join(dir, ".bv", "recipes.yaml"), `recipes:
  as-json:
    description: Open beads as JSON, no graph
    filters:
      status: [open]
    export:
      format: json
      include_graph: false
  templated:
    description: The fixture through a template
    export:
      template: `+template+`
`)
	s, err := Open(OpenConfig{Path: dir})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)
	return s, template
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func exportErr(t *testing.T, s *Session, req map[string]any) error {
	t.Helper()
	raw, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Call("export_report", raw)
	return err
}

// With nothing given the report is bv's default: Markdown, the graph
// included, titled "Beads Export", stamped with the pinned clock.
func TestReportDefaultsToBvsMarkdown(t *testing.T) {
	setClock(t, readinessClock)
	s, _ := openReportFixture(t)
	r := call[reportShape](t, s, "export_report", nil)

	if r.Format != "markdown" || !r.IncludeGraph || r.Title != "Beads Export" {
		t.Errorf("options = %q graph=%v title=%q", r.Format, r.IncludeGraph, r.Title)
	}
	if !strings.HasPrefix(r.Content, "# Beads Export\n\n*Generated: "+readinessClock.Format(time.RFC1123)+"*") {
		t.Errorf("header does not carry the pinned clock:\n%s", r.Content[:80])
	}
	if !strings.Contains(r.Content, "```mermaid") {
		t.Error("the default report has no dependency graph")
	}
	if r.IssueCount != 5 || r.Bytes != len(r.Content) || r.Path != "" {
		t.Errorf("issue_count=%d bytes=%d path=%q", r.IssueCount, r.Bytes, r.Path)
	}
	if r.LabelMatches != nil {
		t.Errorf("label_matches = %d with no label requested", *r.LabelMatches)
	}
}

func TestReportTitleIsTheCallersWhenGiven(t *testing.T) {
	s, _ := openReportFixture(t)
	r := call[reportShape](t, s, "export_report", map[string]any{"title": "Demo — Bead Report"})
	if !strings.HasPrefix(r.Content, "# Demo — Bead Report\n") {
		t.Errorf("title not applied: %q", r.Content[:40])
	}
}

// Each format renders through bv's GenerateReport, with bv's per-format graph
// default: on for all but CSV.
func TestReportFormats(t *testing.T) {
	s, _ := openReportFixture(t)
	cases := []struct {
		format, prefix string
		graph          bool
	}{
		{"json", "{\n  \"title\": \"Beads Export\"", true},
		{"csv", "id,title,status,priority,issue_type,description,labels\n", false},
		{"mermaid", "graph TD\n", true},
	}
	for _, c := range cases {
		r := call[reportShape](t, s, "export_report", map[string]any{"format": c.format})
		if r.Format != c.format || r.IncludeGraph != c.graph {
			t.Errorf("%s: format=%q graph=%v", c.format, r.Format, r.IncludeGraph)
		}
		if !strings.HasPrefix(r.Content, c.prefix) {
			t.Errorf("%s: content starts %q", c.format, r.Content[:min(60, len(r.Content))])
		}
	}
}

// The JSON report carries vbx's provenance: the unscoped data hash and the
// source it was loaded from, in bv's vocabulary.
func TestJSONReportCarriesProvenance(t *testing.T) {
	s, _ := openReportFixture(t)
	info := call[infoPayload](t, s, "info", nil)
	r := call[reportShape](t, s, "export_report", map[string]any{"format": "json", "label": "core"})
	var body struct {
		DataHash   string            `json:"data_hash"`
		SourceKind string            `json:"source_kind"`
		SourcePath string            `json:"source_path"`
		Issues     []json.RawMessage `json:"issues"`
		Graph      *struct {
			Nodes int `json:"nodes"`
		} `json:"graph"`
	}
	if err := json.Unmarshal([]byte(r.Content), &body); err != nil {
		t.Fatal(err)
	}
	if body.DataHash != info.DataHash {
		t.Errorf("data_hash %q is not the unscoped %q", body.DataHash, info.DataHash)
	}
	if body.SourceKind != "jsonl_local" || body.SourcePath != info.Source {
		t.Errorf("source = %q %q", body.SourceKind, body.SourcePath)
	}
	if len(body.Issues) != 2 || body.Graph == nil {
		t.Errorf("issues=%d graph=%v", len(body.Issues), body.Graph)
	}
}

// bv's rejections come back as errors, in bv's words.
func TestReportRejectsWhatBvRejects(t *testing.T) {
	s, template := openReportFixture(t)
	cases := []struct {
		req  map[string]any
		want string
	}{
		{map[string]any{"format": "pdf"}, `export format "pdf" must be markdown, json, csv or mermaid`},
		{map[string]any{"format": "csv", "include_graph": true}, "CSV cannot include a graph"},
		{map[string]any{"format": "mermaid", "include_graph": false}, "Mermaid export requires include_graph=true"},
		{map[string]any{"format": "json", "template": template}, "custom templates require markdown export"},
		{map[string]any{"template": filepath.Join(t.TempDir(), "absent")}, "rendering report: read export template"},
		{map[string]any{"recipe": "no-such-recipe"}, "no-such-recipe"},
	}
	for _, c := range cases {
		err := exportErr(t, s, c.req)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%v: err = %v, want %q", c.req, err, c.want)
		}
	}
}

// A label scope reports the label's own beads; their blockers outside it
// stay in the graph as context, as in bv.
func TestReportLabelScope(t *testing.T) {
	s, _ := openReportFixture(t)
	r := call[reportShape](t, s, "export_report", map[string]any{"label": "core", "format": "mermaid"})
	if r.IssueCount != 2 || r.LabelMatches == nil || *r.LabelMatches != 2 {
		t.Errorf("issue_count=%d label_matches=%v", r.IssueCount, r.LabelMatches)
	}
	if !strings.Contains(r.Content, `c["c<br/>Charlie"]`) {
		t.Errorf("the out-of-label blocker c is missing from the graph:\n%s", r.Content)
	}
	if strings.Contains(r.Content, `d["d`) {
		t.Errorf("unrelated d is in a core-scoped graph:\n%s", r.Content)
	}

	none := call[reportShape](t, s, "export_report", map[string]any{"label": "no-such-label"})
	if none.IssueCount != 0 || none.LabelMatches == nil || *none.LabelMatches != 0 {
		t.Errorf("unknown label: issue_count=%d label_matches=%v", none.IssueCount, none.LabelMatches)
	}
}

// A recipe's export block supplies the defaults, and an explicit option —
// including false and the empty template — overrides each one.
func TestReportRecipeDefaults(t *testing.T) {
	s, template := openReportFixture(t)

	r := call[reportShape](t, s, "export_report", map[string]any{"recipe": "as-json"})
	if r.Format != "json" || r.IncludeGraph {
		t.Errorf("recipe defaults not applied: format=%q graph=%v", r.Format, r.IncludeGraph)
	}
	if r.IssueCount != 4 {
		t.Errorf("the open-status filter selected %d beads, want a-d (e is in progress)", r.IssueCount)
	}

	r = call[reportShape](t, s, "export_report", map[string]any{"recipe": "as-json", "format": "markdown", "include_graph": true})
	if r.Format != "markdown" || !r.IncludeGraph {
		t.Errorf("explicit options lost to the recipe: format=%q graph=%v", r.Format, r.IncludeGraph)
	}

	r = call[reportShape](t, s, "export_report", map[string]any{"recipe": "templated"})
	if r.Template != template || r.Content != "Beads Export: a b c d e|graph\n" {
		t.Errorf("recipe template: template=%q content=%q", r.Template, r.Content)
	}

	r = call[reportShape](t, s, "export_report", map[string]any{"recipe": "templated", "template": "", "include_graph": false})
	if r.Template != "" || !strings.HasPrefix(r.Content, "# Beads Export") || strings.Contains(r.Content, "```mermaid") {
		t.Errorf("an explicit empty template did not disable the recipe's: %q", r.Content[:min(60, len(r.Content))])
	}
}

func TestReportWritesToPath(t *testing.T) {
	s, _ := openReportFixture(t)
	out := filepath.Join(t.TempDir(), "report.csv")
	r := call[reportShape](t, s, "export_report", map[string]any{"format": "csv", "path": out})
	written, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if r.Path != out || string(written) != r.Content {
		t.Errorf("path=%q, file matches content: %v", r.Path, string(written) == r.Content)
	}
	if err := exportErr(t, s, map[string]any{"path": "/definitely/not/a/directory/r.md"}); err == nil {
		t.Error("an unwritable path did not fail")
	}
}
