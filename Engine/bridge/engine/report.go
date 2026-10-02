package engine

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/export"
	"github.com/Dicklesworthstone/beads_viewer/pkg/hooks"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	"github.com/Dicklesworthstone/beads_viewer/pkg/recipe"
)

// Reports: bv 0.25's `--export` / `--export-md`.
//
// bv renders every report through two exported functions —
// export.ResolveReportOptions, which layers the explicit flags over a
// recipe's `export:` defaults, and export.GenerateReport, which renders the
// selected beads as markdown, json, csv or mermaid. vbx calls both; nothing
// here formats a report. What lives in `cmd/bv` and so has to be ported is
// the wiring around them: which beads are selected, which are context, and
// the provenance stamped on the result. Each step below names the bv code it
// follows.

// reportRequest is one export. The three pointer fields are bv's
// ReportOverrides: nil means "not given", so a recipe default applies, while
// a pointer to false or to "" deliberately overrides it.
type reportRequest struct {
	Format       *string `json:"format"`
	IncludeGraph *bool   `json:"include_graph"`
	Template     *string `json:"template"`
	// Recipe is a recipe name or a .yaml/.yml path, resolved as bv's
	// --recipe is. It selects and orders the beads and supplies export
	// defaults.
	Recipe string `json:"recipe"`
	// Label is bv's global --label scope: the report covers the label's own
	// beads, with the subgraph as dependency context.
	Label string `json:"label"`
	// Title replaces bv's fixed "Beads Export". bv has no flag for it, so
	// vbx-cli never sends one; the app names the report after the workspace.
	Title string `json:"title"`
	// Path, when set, writes the report to disk as well as returning it.
	Path string `json:"path"`
	// HooksDir is the project directory whose .bv/hooks.yaml is run around
	// the write. Empty is bv's choice, the working directory. Read only when
	// the session was opened with ExportHooks and Path is set.
	HooksDir string `json:"hooks_dir"`
}

// reportPayload is what the engine returns. The content always comes back,
// so a sandboxed caller can write it wherever its save panel allows.
type reportPayload struct {
	Content      string `json:"content"`
	Format       string `json:"format"`
	IncludeGraph bool   `json:"include_graph"`
	Template     string `json:"template"`
	Title        string `json:"title"`
	IssueCount   int    `json:"issue_count"`
	Bytes        int    `json:"bytes"`
	Path         string `json:"path"`
	// LabelMatches is how many beads carry the requested label, present only
	// when one was requested: bv warns when it is zero.
	LabelMatches *int `json:"label_matches,omitempty"`
	// HookOutput is what bv prints to stdout around the write — each hook
	// as it starts, the summary, and the failure line — byte for byte, for
	// the caller to print after its "Exporting" line. HookFailed is bv's
	// os.Exit(1): a pre-export hook failed (and nothing was written) or an
	// `on_error: fail` post-export hook did (after the write).
	HookOutput string `json:"hook_output,omitempty"`
	HookFailed bool   `json:"hook_failed,omitempty"`
}

// exportReport renders a report the way `bv --export` does.
func (s *Session) exportReport(req []byte) ([]byte, error) {
	var r reportRequest
	if len(req) > 0 {
		if err := json.Unmarshal(req, &r); err != nil {
			return nil, err
		}
	}

	var active *recipe.Recipe
	if r.Recipe != "" {
		var err error
		active, err = s.resolveRecipe(r.Recipe)
		if err != nil {
			return nil, err
		}
	}

	var defaults recipe.ExportConfig
	if active != nil {
		defaults = active.Export
	}
	options, err := export.ResolveReportOptions(defaults, export.ReportOverrides{
		Format: r.Format, IncludeGraph: r.IncludeGraph, Template: r.Template,
	})
	if err != nil {
		return nil, err
	}
	if r.Title != "" {
		options.Title = r.Title
	}

	issues, analyzer, stats := s.snapshot()
	selected, labelMatches, err := s.reportSelection(issues, stats, r.Label, active)
	if err != nil {
		return nil, err
	}

	// bv's provenance, from its RobotContext envelope. The data hash is the
	// unscoped one, as bv's is under a label or recipe; source_authority and
	// authority_hash stay empty because vbx ranks no sources (ADR-023).
	// AuthorityComplete is bv's claimsProven — vbx never exports at a
	// revision, so bv's `&& asOf == ""` always holds.
	s.mu.RLock()
	source, kind := s.source, s.kind
	s.mu.RUnlock()
	options.GeneratedAt = robotNow()
	options.Readiness = s.readinessIndex()
	options.AuthorityComplete = s.claimsProven()
	if analyzer != nil {
		options.DataHash = analyzer.DataHash()
	}
	options.SourcePath = source
	options.SourceKind = sourceKindForEnvelope(kind)

	// The whole visible set is the context — bv's issuesForSearch — so a
	// selected bead's blocker outside the selection still appears in the
	// graph.
	content, err := export.GenerateReport(selected, issues, options)
	if err != nil {
		return nil, fmt.Errorf("rendering report: %w", err)
	}

	payload := reportPayload{
		Content:      string(content),
		Format:       options.Format,
		IncludeGraph: options.IncludeGraph,
		Template:     options.Template,
		Title:        options.Title,
		IssueCount:   len(selected),
		Bytes:        len(content),
		LabelMatches: labelMatches,
	}
	if r.Path != "" {
		hooksDir := ""
		if s.config.ExportHooks {
			hooksDir = r.HooksDir
			if hooksDir == "" {
				hooksDir, _ = os.Getwd()
			}
		}
		if err := writeReport(&payload, r.Path, content, hooks.ExportContext{
			ExportPath:   r.Path,
			ExportFormat: options.Format,
			IssueCount:   len(selected),
			Timestamp:    options.GeneratedAt,
		}, s.config.ExportHooks, hooksDir); err != nil {
			return nil, err
		}
	}
	return json.Marshal(payload)
}

// writeReport writes a rendered report to path, running the project's export
// hooks around the write when runHooks is set — bv's export branch in
// cmd/bv, from loading .bv/hooks.yaml to the post-export summary. The hooks
// themselves are bv's pkg/hooks: its loader, its executor (environment,
// credential scrubbing, timeouts, on_error) and its summary. Only the
// printing is redirected, into payload.HookOutput, because the engine has no
// stdout of its own; the text is bv's, line for line.
func writeReport(payload *reportPayload, path string, content []byte,
	ctx hooks.ExportContext, runHooks bool, hooksDir string) error {
	var out strings.Builder
	var executor *hooks.Executor
	if runHooks {
		loader := hooks.NewLoader(hooks.WithProjectDir(hooksDir))
		if err := loader.Load(); err != nil {
			fmt.Fprintf(&out, "Warning: failed to load hooks: %v\n", err)
		} else if loader.HasHooks() {
			executor = hooks.NewExecutor(loader.Config(), ctx)
			executor.SetLogger(func(msg string) {
				fmt.Fprintf(&out, "  → %s\n", msg)
			})
			if err := executor.RunPreExport(); err != nil {
				fmt.Fprintf(&out, "Error: pre-export hook failed: %v\n", err)
				payload.HookOutput, payload.HookFailed = out.String(), true
				return nil
			}
		}
	}

	if err := os.WriteFile(path, content, 0o644); err != nil {
		return fmt.Errorf("writing %s: %w", path, err)
	}
	payload.Path = path

	if executor != nil {
		postErr := executor.RunPostExport()
		if len(executor.Results()) > 0 {
			fmt.Fprintln(&out, executor.Summary())
		}
		if postErr != nil {
			fmt.Fprintf(&out, "Error: %v (export written to %s)\n", postErr, path)
			payload.HookFailed = true
		}
	}
	payload.HookOutput = out.String()
	return nil
}

// reportSelection is the beads a report renders, in the order it renders
// them: bv's scopeLoadedIssues followed by its candidate filter in the export
// branch. A label narrows to the label's subgraph with its own beads as the
// candidates; a recipe then filters and orders those candidates, max_items
// cap included (unlike recipe_apply, which reports the uncapped count), with
// its metrics taken over the whole source, as bv's are.
func (s *Session) reportSelection(
	issues []model.Issue, stats *analysis.GraphStats, label string, active *recipe.Recipe,
) (selected []model.Issue, labelMatches *int, err error) {
	selected = issues
	var candidates map[string]bool
	if label != "" {
		subgraph := analysis.ComputeLabelSubgraph(issues, label)
		candidates = make(map[string]bool, len(subgraph.CoreIssues))
		for _, id := range subgraph.CoreIssues {
			candidates[id] = true
		}
		matches := len(subgraph.CoreIssues)
		labelMatches = &matches
		selected = make([]model.Issue, 0, len(subgraph.AllIssues))
		for _, id := range subgraph.AllIssues {
			if issue, ok := subgraph.IssueMap[id]; ok {
				selected = append(selected, issue)
			}
		}
	}
	if candidates != nil {
		selected = onlyCandidates(selected, candidates)
	}
	if active != nil {
		applied, err := recipe.Apply(selected, s.recipeMetrics(issues, active, stats), active, robotNow())
		if err != nil {
			return nil, nil, fmt.Errorf("recipe %s: %w", active.Name, err)
		}
		selected = applied
	}
	return selected, labelMatches, nil
}

// onlyCandidates keeps the issues a candidate set names, in their order.
func onlyCandidates(issues []model.Issue, candidates map[string]bool) []model.Issue {
	kept := make([]model.Issue, 0, len(candidates))
	for _, issue := range issues {
		if candidates[issue.ID] {
			kept = append(kept, issue)
		}
	}
	return kept
}
