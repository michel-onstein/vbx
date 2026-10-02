package engine

import (
	"sort"
	"strings"
	"testing"

	"github.com/Dicklesworthstone/beads_viewer/pkg/drift"
)

// alertKeys is each alert as "type/issue", sorted, for comparing with bv.
func alertKeys(result alertsShape) []string {
	keys := make([]string, 0, len(result.Alerts))
	for _, alert := range result.Alerts {
		keys = append(keys, alert.Type+"/"+alert.IssueID)
	}
	sort.Strings(keys)
	return keys
}

// Regression (vbx-jnm): the alert label filter kept every alert carrying no
// label, so on the demo `engine`, `ui` and an unknown label all returned the
// 18 unfiltered alerts. bv 0.25.2's --alert-label keeps only the alerts that
// name the label, and its global --label scopes the issue set the alerts are
// computed over; both apply together. Every expectation below is bv 0.25.2
// --robot-alerts over Fixtures/demo at SOURCE_DATE_EPOCH=1788000000.
func TestAlertLabelsMatchBV(t *testing.T) {
	t.Setenv("SOURCE_DATE_EPOCH", "1788000000")
	s := openDemo(t)

	stale := func(ids ...string) []string {
		out := make([]string, 0, len(ids))
		for _, id := range ids {
			out = append(out, "stale_issue/"+id)
		}
		return out
	}
	cases := []struct {
		name string
		req  map[string]any
		want []string
	}{
		{"alert-label engine", map[string]any{"alert_label": "engine"}, append(
			[]string{"abandoned_claim/vbx-3", "blocking_cascade/vbx-3", "high_impact_unblock/vbx-3"},
			stale("vbx-10", "vbx-16", "vbx-3")...)},
		{"alert-label is trimmed and case-blind", map[string]any{"alert_label": " Engine "}, append(
			[]string{"abandoned_claim/vbx-3", "blocking_cascade/vbx-3", "high_impact_unblock/vbx-3"},
			stale("vbx-10", "vbx-16", "vbx-3")...)},
		{"alert-label ui", map[string]any{"alert_label": "ui"},
			stale("vbx-13", "vbx-17", "vbx-18", "vbx-4", "vbx-5", "vbx-6", "vbx-7", "vbx-8", "vbx-9")},
		{"alert-label unknown", map[string]any{"alert_label": "no-such-label"}, nil},
		{"label engine", map[string]any{"label": "engine"}, append(
			[]string{"abandoned_claim/vbx-3"},
			stale("vbx-10", "vbx-11", "vbx-12", "vbx-16", "vbx-3", "vbx-4", "vbx-5", "vbx-6", "vbx-7", "vbx-8")...)},
		{"label ui", map[string]any{"label": "ui"}, append(
			[]string{"abandoned_claim/vbx-3"},
			stale("vbx-12", "vbx-13", "vbx-17", "vbx-18", "vbx-3", "vbx-4", "vbx-5", "vbx-6", "vbx-7", "vbx-8", "vbx-9")...)},
		{"label unknown", map[string]any{"label": "no-such-label"}, nil},
		{"label engine, alert-label ui", map[string]any{"label": "engine", "alert_label": "ui"},
			stale("vbx-4", "vbx-5", "vbx-6", "vbx-7", "vbx-8")},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := call[alertsShape](t, s, "alerts", tc.req)
			want := append([]string{}, tc.want...)
			sort.Strings(want)
			if strings.Join(alertKeys(got), ",") != strings.Join(want, ",") {
				t.Errorf("alerts = %v, want bv's %v", alertKeys(got), want)
			}
			if got.Summary.Total != len(got.Alerts) {
				t.Errorf("summary total %d for %d alerts", got.Summary.Total, len(got.Alerts))
			}
		})
	}
}

// A workspace-wide alert names no label, so a label filter drops it rather
// than keeping it — the rule vbx-jnm got backwards.
func TestAlertMatchesLabelDropsWorkspaceWideAlerts(t *testing.T) {
	workspace := drift.Alert{Type: drift.AlertNewCycle, Details: []string{"a → b → a"}}
	if alertMatchesLabel(workspace, "engine") {
		t.Error("a workspace-wide alert matched a label it does not name")
	}
	if !alertMatchesLabel(workspace, "") {
		t.Error("no label must keep every alert")
	}
	if !alertMatchesLabel(drift.Alert{Labels: []string{"Engine"}}, "engine") {
		t.Error("an alert on an issue carrying the label did not match")
	}
	// Issue labels match exactly, not by substring; details match by substring.
	if alertMatchesLabel(drift.Alert{Labels: []string{"engineering"}}, "engine") {
		t.Error("an issue label matched by substring")
	}
	if !alertMatchesLabel(drift.Alert{Details: []string{"label: engine"}}, "engine") {
		t.Error("a detail naming the label did not match")
	}
}
