package engine

import (
	"reflect"
	"slices"
	"sort"

	"github.com/Dicklesworthstone/beads_viewer/pkg/loader"
	"github.com/Dicklesworthstone/beads_viewer/pkg/workspace"
)

// bv 0.25 (#190) adds `load_stats` to every robot envelope whose load dropped
// a record — malformed JSON, or a record that failed validation such as
// updated_at before created_at — so an agent can tell "absent from the data"
// from "silently dropped by the loader". vbx-dv5.
//
// bv builds it in `cmd/bv`, which vbx cannot import, from its per-source
// authority report (`robotLoadStats` over `RobotSourceAuthority`). The source
// authority itself is not ported (ADR-023), but the part load_stats reads is
// only per-source parse accounting, which vbx's loads already produce: bv's
// own `loader.ParseStats` for a JSONL, bv's `workspace.LoadResult` for each
// workspace member, and vbx's SQLite reader, which counts the rows it drops by
// bv's SQLite rule. So the counts are the loaders', never a recount.
//
// What vbx cannot reproduce is bv's source-selection warnings — a rejected
// fresher candidate, a stale fallback — because vbx ranks no sources
// (ADR-024). Those are bv's AuthorityWarnings and only ever join the warning
// list; the counts do not depend on them.

// maxSourceWarnings is bv's cap on the warnings one source reports, and on
// the warnings load_stats carries in all.
const maxSourceWarnings = 10

// maxWarningRunes is bv's boundedSourceMessage limit.
const maxWarningRunes = 1024

// sourceLoad is one source's parse accounting: bv's RobotSourceReport, cut to
// the fields load_stats reads.
type sourceLoad struct {
	name       string
	repoPath   string
	sourcePath string
	// disabled is a workspace member the configuration switched off: listed,
	// but counted in nothing.
	disabled bool
	stats    loader.ParseStats
	// warnings are the source's first maxSourceWarnings messages, in order.
	warnings []string
}

// loadStats is bv's RobotLoadStats, field for field.
type loadStats struct {
	SourcePath string   `json:"source_path,omitempty"`
	Valid      int      `json:"valid"`
	Errors     int      `json:"errors"`
	Skipped    int      `json:"skipped"`
	Warnings   []string `json:"warnings,omitempty"`
}

// warningRecorder collects a parse's warnings for a sourceLoad, keeping the
// first maxSourceWarnings as bv's load recorder does.
type warningRecorder struct {
	kept []string
}

func (r *warningRecorder) add(message string) {
	if len(r.kept) < maxSourceWarnings {
		r.kept = append(r.kept, message)
	}
}

// workspaceSourceLoads is bv's robotWorkspaceAuthority, cut to what
// load_stats reads: each member's parse accounting, its source-selection
// warnings first and then its parse warnings.
func workspaceSourceLoads(results []workspace.LoadResult) []sourceLoad {
	loads := make([]sourceLoad, 0, len(results))
	for _, result := range results {
		loads = append(loads, sourceLoad{
			name:       result.RepoName,
			repoPath:   result.RepoPath,
			sourcePath: result.SourcePath,
			disabled:   result.Disabled,
			stats:      result.ParseStats,
			warnings: append(append([]string(nil), result.AuthorityWarnings...),
				result.ParseWarnings...),
		})
	}
	return loads
}

// boundedWarning is bv's boundedSourceMessage.
func boundedWarning(message string) string {
	runes := []rune(message)
	if len(runes) > maxWarningRunes {
		return string(runes[:maxWarningRunes]) + "…"
	}
	return message
}

// robotLoadStats is bv's robotLoadStats over newRobotSourceAuthority: nil
// unless some source dropped a record.
//
// The counts sum every source that is not disabled — a member that failed to
// load included, as bv's do. source_path is named only when there is exactly
// one source, disabled ones counted. The warnings are the sources' in bv's
// source order (repository path, name, source path), each source capped and
// each message bounded, and then capped again in all.
func robotLoadStats(sources []sourceLoad) *loadStats {
	ordered := append([]sourceLoad(nil), sources...)
	sort.SliceStable(ordered, func(i, j int) bool {
		a, b := ordered[i], ordered[j]
		if a.repoPath != b.repoPath {
			return a.repoPath < b.repoPath
		}
		if a.name != b.name {
			return a.name < b.name
		}
		return a.sourcePath < b.sourcePath
	})

	stats := &loadStats{}
	for _, source := range ordered {
		if source.disabled {
			continue
		}
		stats.Valid += source.stats.Valid
		stats.Errors += source.stats.Errors
		stats.Skipped += source.stats.Skipped
	}
	if stats.Errors == 0 {
		return nil
	}
	if len(ordered) == 1 {
		stats.SourcePath = ordered[0].sourcePath
	}
	for _, source := range ordered {
		warnings := source.warnings
		if len(warnings) > maxSourceWarnings {
			warnings = warnings[:maxSourceWarnings]
		}
		for _, warning := range warnings {
			if len(stats.Warnings) < maxSourceWarnings {
				stats.Warnings = append(stats.Warnings, boundedWarning(warning))
			}
		}
	}
	return stats
}

// refreshAccounting replaces the session's load accounting — the source
// loads, the warnings and the claim-safety verdict — after a reload whose
// bead set did not change, and reports whether anything the app is shown of
// it did: load_stats, the warnings or the verdict. A member added with no
// beads changes the source list but none of those, and stays unchanged.
func (s *Session) refreshAccounting(loads []sourceLoad, warnings []string, complete bool) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	changed := !reflect.DeepEqual(robotLoadStats(s.sourceLoads), robotLoadStats(loads)) ||
		!slices.Equal(s.warnings, warnings) || s.complete != complete
	s.sourceLoads, s.warnings, s.complete = loads, warnings, complete
	return changed
}
