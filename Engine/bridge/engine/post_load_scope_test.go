package engine

import (
	"encoding/json"
	"slices"
	"sort"
	"strings"
	"testing"
)

// bv 0.25.2 applies --label and --recipe before every post-load robot
// handler, not only the nine vbx-cli scoped first. Regression (vbx-shz): the
// label commands, the blocker chain, the sprint commands and search answered
// over every bead under either flag, with no scope in the envelope. Each
// expected value here is bv 0.25.2's over the same fixture at parity-check's
// PINNED_CLOCK.

// scopeEnvelope is the part of a payload's envelope a scope shows in.
type scopeEnvelope struct {
	DataHash  string `json:"data_hash"`
	ScopeHash string `json:"scope_hash"`
	Scope     *struct {
		Label  string `json:"label"`
		Recipe string `json:"recipe"`
	} `json:"scope"`
}

func TestLabelCommandsAnswerOverTheScope(t *testing.T) {
	setClock(t, readinessClock)
	s := openDemoFull(t)
	// The unscoped demo hash, which bv's label commands carry under any
	// scope: their envelope is ctx.Envelope().
	const demoHash = "0e588914e7e68afcd509715ec5986f236be5660fb00a548b78093a178f97808f"

	type health struct {
		scopeEnvelope
		TotalLabels int `json:"total_labels"`
		Labels      []struct {
			Label string `json:"label"`
		} `json:"labels"`
	}
	got := call[health](t, s, "label_health", map[string]any{"label": "engine"})
	labels := make([]string, 0, len(got.Labels))
	for _, l := range got.Labels {
		labels = append(labels, l.Label)
	}
	sort.Strings(labels)
	// The engine subgraph's labels: its beads' and their neighbours'. The
	// whole demo has 22.
	want := "agents,algorithms,analytics,architecture,board,build,cli,correlation,engine," +
		"graph,list,loader,sandbox,swift,tree,ui,watch"
	if got.TotalLabels != 17 || strings.Join(labels, ",") != want {
		t.Errorf("label_health --label engine: %d labels %v, want bv's 17", got.TotalLabels, labels)
	}
	if got.Scope == nil || got.Scope.Label != "engine" ||
		got.ScopeHash != demoScopeHashes["engine"] || got.DataHash != demoHash {
		t.Errorf("label_health envelope = %+v, want scope engine, bv's hashes", got.scopeEnvelope)
	}

	unknown := call[health](t, s, "label_health", map[string]any{"label": "no-such-label"})
	if unknown.TotalLabels != 0 || unknown.ScopeHash != demoScopeHashes["no-such-label"] {
		t.Errorf("label_health --label no-such-label: %d labels, scope_hash %s",
			unknown.TotalLabels, unknown.ScopeHash)
	}

	type flow struct {
		scopeEnvelope
		Labels []string `json:"labels"`
		Total  int      `json:"total_cross_label_deps"`
	}
	flowed := call[flow](t, s, "label_flow", map[string]any{"recipe": "actionable"})
	if strings.Join(flowed.Labels, ",") != "algorithms,engine,graph,release,swift" ||
		flowed.Total != 0 || flowed.Scope == nil || flowed.Scope.Recipe != "actionable" ||
		flowed.ScopeHash != "79d68f58967a0eb368575694734763e77e5009c8b134cd6f28ab492e7f692fbe" {
		t.Errorf("label_flow --recipe actionable = %+v", flowed)
	}

	type attention struct {
		scopeEnvelope
		TotalLabels int `json:"total_labels"`
	}
	attended := call[attention](t, s, "label_attention", map[string]any{"label": "ui"})
	if attended.TotalLabels != 13 ||
		attended.ScopeHash != "d6babea209de8717156edc1a3a83cbcd9cf9ad6b1dfcff6332f27d5aef2764ab" {
		t.Errorf("label_attention --label ui: %d labels, scope_hash %s",
			attended.TotalLabels, attended.ScopeHash)
	}

	// Unscoped, every label and no scope.
	whole := call[health](t, s, "label_health", nil)
	if whole.TotalLabels != 22 || whole.Scope != nil || whole.DataHash != demoHash {
		t.Errorf("label_health unscoped: %d labels, scope %+v", whole.TotalLabels, whole.Scope)
	}
}

func TestBlockerChainIsTracedThroughTheScope(t *testing.T) {
	setClock(t, readinessClock)
	s := openDemoFull(t)
	type chain struct {
		scopeEnvelope
		Chain []struct {
			ID     string `json:"id"`
			IsRoot bool   `json:"is_root"`
		} `json:"chain"`
	}
	roots := func(got chain) string {
		out := []string{}
		for _, entry := range got.Chain {
			if entry.IsRoot {
				out = append(out, entry.ID)
			}
		}
		return strings.Join(out, ",")
	}

	whole := call[chain](t, s, "blocker_chain", map[string]any{"id": "vbx-6"})
	if roots(whole) != "vbx-12,vbx-3" || whole.Scope != nil {
		t.Errorf("unscoped roots = %s, want bv's vbx-12,vbx-3", roots(whole))
	}
	// Under --label graph bv's chain holds vbx-3 but not as a root, and its
	// data_hash is the scoped set's.
	scoped := call[chain](t, s, "blocker_chain", map[string]any{"id": "vbx-6", "label": "graph"})
	if roots(scoped) != "vbx-12" || len(scoped.Chain) != 3 ||
		scoped.DataHash != "b1535760c3c75a4f907494e70b5a4d9c998961915167fb61f4a80be3f05d4647" ||
		scoped.ScopeHash != "43582dd4d8efe0bc4fe9d5bd51705813ad40f62df5230633a712f2b2b3d79bbc" {
		t.Errorf("--label graph: roots %s of %d, envelope %+v",
			roots(scoped), len(scoped.Chain), scoped.scopeEnvelope)
	}

	// A bead the scope leaves out is bv's "Issue not found", not a null chain.
	for _, req := range []string{`{"id":"vbx-6","label":"no-such-label"}`, `{"id":"nope"}`} {
		_, err := s.Call("blocker_chain", []byte(req))
		if err == nil || !strings.HasPrefix(err.Error(), "Issue not found: ") {
			t.Errorf("blocker_chain %s: err = %v, want bv's Issue not found", req, err)
		}
	}
}

func TestSprintCommandsAnswerOverTheScope(t *testing.T) {
	setClock(t, readinessClock)
	s := openSprints(t)
	// bv's hashes for --label at-risk: data_hash over the scoped issues, as
	// every sprint command takes it.
	const (
		atRiskHash  = "dc00a16745acdb0d432046c5af08a0e4967bc932cf4bb637079198b7608ee092"
		atRiskScope = "eb43d6804dabaddcb3082e323bb32fd5108af3ef8e88eb7e3cc0c718f2ec500f"
	)
	scope := map[string]any{"label": "at-risk"}

	type list struct {
		scopeEnvelope
		SprintCount int `json:"sprint_count"`
	}
	listed := call[list](t, s, "sprint_list", scope)
	if listed.SprintCount != 3 || listed.DataHash != atRiskHash || listed.ScopeHash != atRiskScope ||
		listed.Scope == nil || listed.Scope.Label != "at-risk" {
		t.Errorf("sprint_list --label at-risk = %+v", listed)
	}

	type show struct {
		scopeEnvelope
		Issues []struct {
			ID     string   `json:"id"`
			Labels []string `json:"labels"`
		} `json:"issues"`
		Missing []string `json:"missing"`
	}
	shown := call[show](t, s, "sprint_show", map[string]any{"id": "spr-sprint-2", "label": "at-risk"})
	if shown.DataHash != atRiskHash || shown.ScopeHash != atRiskScope {
		t.Errorf("sprint_show envelope = %+v", shown.scopeEnvelope)
	}
	// The scope's beads: the label's and their direct neighbours.
	listedIDs := []string{}
	labelled := 0
	for _, issue := range shown.Issues {
		listedIDs = append(listedIDs, issue.ID)
		if slices.Contains(issue.Labels, "at-risk") {
			labelled++
		}
	}
	whole := call[show](t, s, "sprint_show", map[string]any{"id": "spr-sprint-2"})
	// Five of sprint 2's beads, as bv's burndown counts below; spr-7 is in
	// only as a neighbour of a labelled bead.
	if labelled != 4 || strings.Join(listedIDs, ",") != "spr-5,spr-6,spr-7,spr-8,spr-9" ||
		len(whole.Issues) != 10 {
		t.Errorf("sprint_show lists %v under the scope (%d labelled), %d beads without",
			listedIDs, labelled, len(whole.Issues))
	}
	// A bead the scope leaves out is not missing: missing is what the
	// workspace no longer has — the tombstoned spr-14 and spr-ghost, which no
	// bead ever was — exactly as without a scope.
	if strings.Join(shown.Missing, ",") != strings.Join(whole.Missing, ",") ||
		strings.Join(shown.Missing, ",") != "spr-14,spr-ghost" {
		t.Errorf("sprint_show missing = %v scoped, %v whole", shown.Missing, whole.Missing)
	}

	type burndown struct {
		scopeEnvelope
		TotalIssues int             `json:"total_issues"`
		IdealLine   json.RawMessage `json:"ideal_line"`
	}
	burned := call[burndown](t, s, "burndown", map[string]any{"id": "spr-sprint-2", "label": "at-risk"})
	if burned.TotalIssues != 5 || burned.DataHash != atRiskHash || burned.ScopeHash != atRiskScope {
		t.Errorf("burndown --label at-risk: %d issues, envelope %+v", burned.TotalIssues,
			burned.scopeEnvelope)
	}
	// None of the sprint's beads in scope: no ideal line, written null as bv
	// writes it.
	empty := call[burndown](t, s, "burndown",
		map[string]any{"id": "spr-sprint-2", "label": "no-such-label"})
	if empty.TotalIssues != 0 || string(empty.IdealLine) != "null" {
		t.Errorf("burndown --label no-such-label: %d issues, ideal_line %s", empty.TotalIssues,
			empty.IdealLine)
	}
}

func TestSearchReturnsOnlyTheScopesBeads(t *testing.T) {
	s, err := Open(OpenConfig{Path: writableFeedbackFixture(t, "search")})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	type found struct {
		scopeEnvelope
		Results []struct {
			IssueID string `json:"issue_id"`
		} `json:"results"`
	}
	ids := func(got found) string {
		out := []string{}
		for _, r := range got.Results {
			out = append(out, r.IssueID)
		}
		return strings.Join(out, ",")
	}

	whole := call[found](t, s, "search", map[string]any{"query": "tax-7", "limit": 3})
	if ids(whole) != "tax-7,srch-2,srch-3" {
		t.Errorf("unscoped = %s, want bv's tax-7,srch-2,srch-3", ids(whole))
	}
	// finance labels tax-7 alone: the decoys around it are not eligible.
	scoped := call[found](t, s, "search", map[string]any{"query": "tax-7", "limit": 3, "label": "finance"})
	if ids(scoped) != "tax-7" || scoped.Scope == nil || scoped.Scope.Label != "finance" ||
		scoped.ScopeHash != "d44c46562045bc05b4699f9fd641d26ea942fa881b993ddc1a07ca4da41dde9f" {
		t.Errorf("--label finance = %s, envelope %+v", ids(scoped), scoped.scopeEnvelope)
	}
	none := call[found](t, s, "search", map[string]any{"query": "tax-7", "limit": 3, "label": "nope"})
	if ids(none) != "" {
		t.Errorf("--label nope = %s, want nothing", ids(none))
	}
}

// Every newly scoped method refuses a recipe that does not resolve, as the
// first nine do (TestUnresolvableRecipeScopeIsAnError).
func TestPostLoadMethodsRefuseAnUnresolvableRecipe(t *testing.T) {
	s := openSprints(t)
	for method, req := range map[string]string{
		"label_health":    `{}`,
		"label_flow":      `{}`,
		"label_attention": `{}`,
		"blocker_chain":   `{"id":"spr-1"}`,
		"sprint_list":     `{}`,
		"sprint_show":     `{"id":"spr-sprint-2"}`,
		"burndown":        `{"id":"spr-sprint-2"}`,
	} {
		var body map[string]any
		_ = json.Unmarshal([]byte(req), &body)
		body["recipe"] = "no-such-recipe"
		raw, _ := json.Marshal(body)
		if _, err := s.Call(method, raw); err == nil || err.Error() != `unknown recipe "no-such-recipe"` {
			t.Errorf("%s with an unknown recipe: err = %v, want bv's", method, err)
		}
	}
}

func openSprints(t *testing.T) *Session {
	t.Helper()
	s, err := Open(OpenConfig{Path: sprintsFixturePath(t)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return s
}
