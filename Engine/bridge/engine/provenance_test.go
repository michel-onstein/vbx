package engine

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// provenanceShape is the part of bv 0.25's envelope vbx ports (ADR-023).
type provenanceShape struct {
	OutputFormat    string                  `json:"output_format"`
	SourcePath      string                  `json:"source_path"`
	SourceKind      string                  `json:"source_kind"`
	ScopeHash       string                  `json:"scope_hash"`
	DataHash        string                  `json:"data_hash"`
	Scope           *struct{ Label string } `json:"scope"`
	SourceAuthority json.RawMessage         `json:"source_authority"`
	AuthorityHash   string                  `json:"authority_hash"`
}

func demoFixturePath(t *testing.T) string {
	t.Helper()
	path, err := filepath.Abs(filepath.Join("..", "..", "..", "Fixtures", "demo"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(path, ".beads", "issues.jsonl")); err != nil {
		t.Fatalf("demo fixture missing: %v", err)
	}
	return path
}

func openDemo(t *testing.T) *Session {
	t.Helper()
	s, err := Open(OpenConfig{Path: demoFixturePath(t), SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return s
}

// Every payload that carries vbx's robot envelope carries the ported
// provenance, with the same values: they describe the load, not the command.
func TestEveryEnvelopeCarriesTheSameProvenance(t *testing.T) {
	setClock(t, readinessClock)
	s, err := Open(OpenConfig{Path: sprintsFixturePath(t), SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	want := filepath.Join(sprintsFixturePath(t), ".beads", "issues.jsonl")
	calls := []struct {
		method string
		req    any
	}{
		{"suggest", nil},
		{"priority", nil},
		{"next", nil},
		{"insights", nil},
		{"graph_export", nil},
		{"burndown", map[string]any{"id": "spr-sprint-2"}},
		// Bare payloads until vbx-6su.
		{"triage", nil},
		{"plan", nil},
		{"alerts", nil},
		{"metrics", nil},
	}
	for _, c := range calls {
		got := call[provenanceShape](t, s, c.method, c.req)
		if got.OutputFormat != "json" {
			t.Errorf("%s: output_format = %q, want json", c.method, got.OutputFormat)
		}
		if got.SourcePath != want {
			t.Errorf("%s: source_path = %q, want %q", c.method, got.SourcePath, want)
		}
		if got.SourceKind != "jsonl_local" {
			t.Errorf("%s: source_kind = %q, want jsonl_local (bv's name for the local JSONL)",
				c.method, got.SourceKind)
		}
		// bv 0.25.2 over Fixtures/sprints, unscoped.
		if got.ScopeHash != "01815a9fb9e28403da59b3fdc672bc08253ae3dc6725f5bcb35d1bdbe441279f" {
			t.Errorf("%s: scope_hash = %q, want bv 0.25.2's", c.method, got.ScopeHash)
		}
		if got.DataHash != "78f236d14ab4590196d3b83afce83ed94117b076c4f2f72bb855315790626519" {
			t.Errorf("%s: data_hash = %q, want bv 0.25.2's", c.method, got.DataHash)
		}
		if got.Scope != nil {
			t.Errorf("%s: an unscoped payload reports a scope", c.method)
		}
		// Declared envelope-only in parity-check.py: never emitted, so never
		// claims a source ranking vbx did not do.
		if got.SourceAuthority != nil || got.AuthorityHash != "" {
			t.Errorf("%s: emits source_authority/authority_hash, which ADR-023 leaves to bv", c.method)
		}
	}
}

// A label scope hashes the label and its core beads, as bv's --label does.
func TestLabelScopeHashMatchesBV(t *testing.T) {
	s := openDemo(t)

	got := call[provenanceShape](t, s, "graph_export", map[string]any{"label": "engine"})
	// bv 0.25.2: --robot-graph --label engine over Fixtures/demo.
	if got.ScopeHash != "88f4076acefdc8f314976afc1e6976ff486f93ad8b1cf0ab4f6cc171ab9935d3" {
		t.Errorf("scope_hash = %q, want bv 0.25.2's", got.ScopeHash)
	}
	if got.Scope == nil || got.Scope.Label != "engine" {
		t.Errorf("scope = %+v, want the label", got.Scope)
	}

	unscoped := call[provenanceShape](t, s, "next", nil)
	if unscoped.ScopeHash != "ae83d9fe042335945c1da01cec2e6ad03d1344e2727c0e25514fd0e2d75b8d1f" {
		t.Errorf("unscoped scope_hash = %q, want bv 0.25.2's", unscoped.ScopeHash)
	}
}

// Triage, plan and alerts carried no envelope until vbx-6su. Under a label
// each names it and hashes its core, and carries the unscoped data hash and a
// generated_at, as bv 0.25.2's --robot-triage, --robot-plan and --robot-alerts
// --label engine do over Fixtures/demo.
func TestTriagePlanAndAlertsCarryTheScopedEnvelope(t *testing.T) {
	setClock(t, readinessClock)
	s := openDemo(t)
	type shape struct {
		provenanceShape
		GeneratedAt string `json:"generated_at"`
	}
	for _, method := range []string{"triage", "plan", "alerts"} {
		got := call[shape](t, s, method, map[string]any{"label": "engine"})
		if got.ScopeHash != "88f4076acefdc8f314976afc1e6976ff486f93ad8b1cf0ab4f6cc171ab9935d3" {
			t.Errorf("%s: scope_hash = %q, want bv 0.25.2's", method, got.ScopeHash)
		}
		if got.DataHash != "0e588914e7e68afcd509715ec5986f236be5660fb00a548b78093a178f97808f" {
			t.Errorf("%s: data_hash = %q, want bv 0.25.2's unscoped hash", method, got.DataHash)
		}
		if got.Scope == nil || got.Scope.Label != "engine" {
			t.Errorf("%s: scope = %+v, want the label", method, got.Scope)
		}
		if got.GeneratedAt != readinessClock.Format(time.RFC3339) {
			t.Errorf("%s: generated_at = %q, want the pinned clock", method, got.GeneratedAt)
		}
	}
}

// The source kind is vbx's own read, in bv's vocabulary — never bv's choice.
func TestSourceKindNamesWhatVBXRead(t *testing.T) {
	dir := t.TempDir()
	beads := filepath.Join(dir, ".beads")
	if err := os.MkdirAll(beads, 0o755); err != nil {
		t.Fatal(err)
	}
	db := makeBeadsDB(t, beads)

	s, err := Open(OpenConfig{Path: dir, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	got := call[provenanceShape](t, s, "suggest", nil)
	if got.SourceKind != "sqlite" || got.SourcePath != db {
		t.Errorf("source = %q %q, want sqlite %q", got.SourceKind, got.SourcePath, db)
	}

	ws := openWorkspace(t)
	got = call[provenanceShape](t, ws, "suggest", nil)
	if got.SourceKind != "workspace" || filepath.Base(got.SourcePath) != "workspace.yaml" {
		t.Errorf("workspace source = %q %q, want workspace and its config", got.SourceKind, got.SourcePath)
	}
}

// The envelope never overwrites a field the payload already has.
func TestProvenanceLeavesThePayloadsOwnKeys(t *testing.T) {
	s := openDemo(t)
	raw, err := s.withProvenance(map[string]any{"source_kind": "data"}, "h", provenanceScope{})
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if got["source_kind"] != "data" {
		t.Errorf("source_kind = %v, want the payload's own value", got["source_kind"])
	}
	if got["output_format"] != "json" {
		t.Errorf("output_format = %v, want json alongside it", got["output_format"])
	}
	if _, err := s.withProvenance([]int{1}, "h", provenanceScope{}); err == nil {
		t.Error("a non-object payload was accepted")
	}
}
