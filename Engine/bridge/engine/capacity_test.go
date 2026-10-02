package engine

import (
	"encoding/json"
	"reflect"
	"testing"
)

type capacityShape struct {
	DataHash           string   `json:"data_hash"`
	Agents             int      `json:"agents"`
	Label              string   `json:"label"`
	OpenIssueCount     int      `json:"open_issue_count"`
	TotalMinutes       int      `json:"total_minutes"`
	SerialMinutes      int      `json:"serial_minutes"`
	ParallelMinutes    int      `json:"parallel_minutes"`
	ParallelizablePct  float64  `json:"parallelizable_pct"`
	EstimatedDays      float64  `json:"estimated_days"`
	CriticalPathLength int      `json:"critical_path_length"`
	CriticalPath       []string `json:"critical_path"`
	ActionableCount    int      `json:"actionable_count"`
	Actionable         []string `json:"actionable"`
	Bottlenecks        []struct {
		ID          string   `json:"id"`
		BlocksCount int      `json:"blocks_count"`
		Blocks      []string `json:"blocks"`
	} `json:"bottlenecks"`
}

func TestCapacityScalesWithAgents(t *testing.T) {
	s := openFixture(t)

	one := call[capacityShape](t, s, "capacity", map[string]any{"agents": 1})
	four := call[capacityShape](t, s, "capacity", map[string]any{"agents": 4})

	if one.OpenIssueCount == 0 {
		t.Fatal("no open beads to simulate")
	}
	if one.TotalMinutes == 0 {
		t.Fatal("the simulation estimated no work at all")
	}
	// More agents cannot make the work take longer, and cannot beat the
	// serial chain either.
	if four.EstimatedDays > one.EstimatedDays {
		t.Errorf("four agents were slower: %v vs %v days", four.EstimatedDays, one.EstimatedDays)
	}
	if four.EstimatedDays*60*8 < float64(four.SerialMinutes) {
		t.Errorf("estimated %v days beat the serial chain of %d minutes",
			four.EstimatedDays, four.SerialMinutes)
	}
	if one.SerialMinutes+one.ParallelMinutes != one.TotalMinutes {
		t.Errorf("serial %d + parallel %d != total %d",
			one.SerialMinutes, one.ParallelMinutes, one.TotalMinutes)
	}
	if one.ParallelizablePct < 0 || one.ParallelizablePct > 100 {
		t.Errorf("parallelizable share is %v%%", one.ParallelizablePct)
	}
}

func TestCapacityCriticalPathFollowsBlockingEdges(t *testing.T) {
	s := openFixture(t)
	result := call[capacityShape](t, s, "capacity", nil)

	// The fixture's chain is c -> b -> a, and c also blocks e. bv measures the
	// chain in steps, so the longest run is c, b, a.
	if want := []string{"c", "b", "a"}; !reflect.DeepEqual(result.CriticalPath, want) {
		t.Errorf("critical path is %v, want %v", result.CriticalPath, want)
	}
	// Only c and d are ready: a, b and e all wait on an open blocker.
	if want := []string{"c", "d"}; !reflect.DeepEqual(result.Actionable, want) {
		t.Errorf("actionable is %v, want %v", result.Actionable, want)
	}
	// c holds up both b and e, so it is the one bottleneck.
	if len(result.Bottlenecks) != 1 || result.Bottlenecks[0].ID != "c" {
		t.Fatalf("bottlenecks were %+v", result.Bottlenecks)
	}
	if want := []string{"b", "e"}; !reflect.DeepEqual(result.Bottlenecks[0].Blocks, want) {
		t.Errorf("c blocks %v, want %v", result.Bottlenecks[0].Blocks, want)
	}
}

// Regression (vbx-ko1): `label` was a filter, and readiness was judged inside
// the filtered set only, so a bead whose blocker carried another label looked
// ready. bv's --capacity-label filters the beads simulated, but readiness
// still reads the whole source: b waits on c whatever c is labelled.
func TestCapacityLabelFiltersWithoutForgettingBlockers(t *testing.T) {
	s := openFixture(t)
	all := call[capacityShape](t, s, "capacity", nil)
	core := call[capacityShape](t, s, "capacity", map[string]any{"capacity_label": "core"})

	if core.OpenIssueCount != 2 || core.OpenIssueCount >= all.OpenIssueCount {
		t.Errorf("--capacity-label core simulated %d beads, want a and b", core.OpenIssueCount)
	}
	if core.Label != "core" {
		t.Errorf("label is %q, want core", core.Label)
	}
	if core.ActionableCount != 0 || len(core.Actionable) != 0 {
		t.Errorf("actionable under core is %v, but b waits on c and a on b", core.Actionable)
	}
	// The filter is bv's exact, case-sensitive match.
	if upper := call[capacityShape](t, s, "capacity", map[string]any{"capacity_label": "CORE"}); upper.OpenIssueCount != 0 {
		t.Errorf("CORE matched %d beads", upper.OpenIssueCount)
	}
	// A blank filter filters nothing and names no label.
	blank := call[capacityShape](t, s, "capacity", map[string]any{"capacity_label": "  "})
	if blank.OpenIssueCount != all.OpenIssueCount || blank.Label != "" {
		t.Errorf("a blank filter gave %d beads labelled %q", blank.OpenIssueCount, blank.Label)
	}
}

// Regression (vbx-ko1): `label` is bv's global scope — the label's core beads
// are simulated, and the envelope hashes the subgraph the analysis ran over.
func TestCapacityLabelIsTheGlobalScope(t *testing.T) {
	s := openFixture(t)
	all := call[capacityShape](t, s, "capacity", nil)
	infra := call[capacityShape](t, s, "capacity", map[string]any{"label": "infra"})

	// infra's core beads are c and e; b is only a neighbour.
	if infra.OpenIssueCount != 2 {
		t.Errorf("--label infra simulated %d beads, want c and e", infra.OpenIssueCount)
	}
	if infra.Label != "" {
		t.Errorf("the scope leaked into the capacity label: %q", infra.Label)
	}
	if infra.DataHash == "" || infra.DataHash == all.DataHash {
		t.Errorf("scoped data_hash %q should hash the subgraph, not the project %q",
			infra.DataHash, all.DataHash)
	}
	// Both together: the filter applies over the scope's candidates.
	both := call[capacityShape](t, s, "capacity", map[string]any{"label": "infra", "capacity_label": "core"})
	if both.OpenIssueCount != 0 {
		t.Errorf("core beads within the infra scope: %d, want none", both.OpenIssueCount)
	}
}

// An empty selection is bv's shape: counts present and zero, the lists absent.
func TestCapacityUnknownLabelOmitsTheLists(t *testing.T) {
	s := openFixture(t)
	for _, req := range []map[string]any{
		{"label": "no-such-label"},
		{"capacity_label": "no-such-label"},
	} {
		raw, _ := json.Marshal(req)
		out, err := s.Call("capacity", raw)
		if err != nil {
			t.Fatal(err)
		}
		var payload map[string]any
		if err := json.Unmarshal(out, &payload); err != nil {
			t.Fatal(err)
		}
		for _, key := range []string{"critical_path", "actionable", "bottlenecks"} {
			if _, ok := payload[key]; ok {
				t.Errorf("%v: %s present on an empty selection", req, key)
			}
		}
		if payload["open_issue_count"] != float64(0) || payload["actionable_count"] != float64(0) {
			t.Errorf("%v: counts were %v and %v", req, payload["open_issue_count"], payload["actionable_count"])
		}
	}
}

func TestLongestCapacityChainTerminatesOnACycle(t *testing.T) {
	// The graph is not guaranteed acyclic — detecting cycles is one of bv's
	// features — so the walk must not recurse forever.
	blocks := map[string][]string{"a": {"b"}, "b": {"c"}, "c": {"a"}}
	chain := longestCapacityChain([]string{"a"}, blocks)
	if want := []string{"a", "b", "c"}; !reflect.DeepEqual(chain, want) {
		t.Errorf("cycle produced chain %v, want %v", chain, want)
	}
}

func TestLongestCapacityChainCountsSteps(t *testing.T) {
	// bv measures the chain in steps: a->b->c beats a->d however long d is.
	blocks := map[string][]string{"a": {"d", "b"}, "b": {"c"}}
	chain := longestCapacityChain([]string{"a"}, blocks)
	if want := []string{"a", "b", "c"}; !reflect.DeepEqual(chain, want) {
		t.Errorf("chose %v, want %v", chain, want)
	}
	// The first longest path in seed order wins a tie.
	tie := longestCapacityChain([]string{"x", "y"}, map[string][]string{"x": {"x1"}, "y": {"y1"}})
	if want := []string{"x", "x1"}; !reflect.DeepEqual(tie, want) {
		t.Errorf("tie chose %v, want %v", tie, want)
	}
	if longestCapacityChain(nil, blocks) != nil {
		t.Error("no seeds should give no chain")
	}
}
