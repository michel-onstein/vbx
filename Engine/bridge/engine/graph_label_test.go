package engine

import (
	"sort"
	"strings"
	"testing"
)

// graphLabelShape is the part of a label-scoped graph export bv 0.25.2's
// answer is checked against.
type graphLabelShape struct {
	Nodes          int               `json:"nodes"`
	Edges          int               `json:"edges"`
	DataHash       string            `json:"data_hash"`
	FiltersApplied map[string]string `json:"filters_applied"`
	Adjacency      *struct {
		Nodes []struct {
			ID string `json:"id"`
		} `json:"nodes"`
	} `json:"adjacency"`
}

// A label-scoped graph is the label's subgraph — its beads and their direct
// dependency neighbours — not only the labelled beads. Regression: vbx handed
// the label to ExportGraph's own filter and exported 6 nodes and 3 edges for
// `engine` on the demo, where bv 0.25.2 exports 13 and 11.
func TestLabelGraphIsTheLabelSubgraph(t *testing.T) {
	s := openDemo(t)

	got := call[graphLabelShape](t, s, "graph_export", map[string]any{"label": "engine"})
	// bv 0.25.2: --robot-graph --label engine --format json over Fixtures/demo.
	want := []string{"vbx-1", "vbx-10", "vbx-11", "vbx-12", "vbx-15", "vbx-16",
		"vbx-2", "vbx-3", "vbx-4", "vbx-5", "vbx-6", "vbx-7", "vbx-8"}
	if got.Nodes != len(want) || got.Edges != 11 {
		t.Errorf("nodes, edges = %d, %d, want bv's %d, 11", got.Nodes, got.Edges, len(want))
	}
	if got.Adjacency == nil {
		t.Fatal("no adjacency")
	}
	ids := make([]string, 0, len(got.Adjacency.Nodes))
	for _, node := range got.Adjacency.Nodes {
		ids = append(ids, node.ID)
	}
	sort.Strings(ids)
	if strings.Join(ids, ",") != strings.Join(want, ",") {
		t.Errorf("nodes = %v, want bv's %v", ids, want)
	}
	if got.FiltersApplied["label"] != "engine" {
		t.Errorf("filters_applied = %v, want the label", got.FiltersApplied)
	}
}

// An unknown label is an empty graph that still names its source data and
// its filter. Regression: the exporter returns early without a data hash or
// filters, and vbx passed that on, where bv's envelope always carries the
// unscoped hash and bv adds the label filter itself.
func TestUnknownLabelGraphKeepsTheDataHash(t *testing.T) {
	s := openDemo(t)

	unscoped := call[graphLabelShape](t, s, "graph_export", nil)
	got := call[graphLabelShape](t, s, "graph_export", map[string]any{"label": "no-such-label"})
	if got.Nodes != 0 || got.Edges != 0 {
		t.Errorf("nodes, edges = %d, %d, want an empty graph", got.Nodes, got.Edges)
	}
	if got.DataHash == "" || got.DataHash != unscoped.DataHash {
		t.Errorf("data_hash = %q, want the unscoped %q", got.DataHash, unscoped.DataHash)
	}
	if got.FiltersApplied["label"] != "no-such-label" {
		t.Errorf("filters_applied = %v, want the label", got.FiltersApplied)
	}
}
