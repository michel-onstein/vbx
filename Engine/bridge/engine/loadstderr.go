package engine

import (
	"fmt"

	"github.com/Dicklesworthstone/beads_viewer/pkg/workspace"
)

// bv prints its loader's warnings to stderr whenever it loads issues outside
// robot mode — no `--robot-*` flag, and `BV_ROBOT` unset. In robot mode it
// keeps stderr clean and reports the same accounting in the envelope's
// load_stats instead. vbx-1l6.
//
// What bv 0.25.2 prints, each line as `Warning: <message>`:
//
//   - a single repository: the discovery warnings for the `.beads` directory
//     (`loadSmart`'s handler for `FindJSONLPathWithWarnings` — leftover merge
//     artifacts), then every parse warning of the JSONL it selects, in file
//     order (`loadRecorder.finish` replays them uncapped; the ten-message cap
//     is only the LoadReport's). A beads.db prints nothing: bv's SQLite reader
//     records its dropped rows in the LoadReport and never prints them.
//   - a workspace: `No .beads directory found; using workspace <config>`
//     when discovery chose it rather than `--workspace` (`cmd/bv`'s
//     auto-discovery), then each member's source-fallback and parse
//     warnings, as its loader meets them, then `Warning: N repos failed to load` and one
//     `  - name` line per failed member (`cmd/bv`'s workspace branch). bv
//     loads members in parallel, so their order is whichever finished first;
//     vbx loads them in turn, which is one of the orders bv can print.
//
// All of it is printed during the load, so before anything the command prints
// itself. The session keeps the lines; vbx-cli decides which commands print
// them, because that is a property of the command — bv's feedback-accept,
// feedback-ignore and export load issues outside robot mode; feedback-show
// and feedback-reset answer without loading.

// stderrWarning is bv's stderr line for one loader warning.
func stderrWarning(message string) string {
	return "Warning: " + message
}

// workspaceFailureStderr is what `cmd/bv` prints after a workspace load in
// which members failed: the count, then each name.
func workspaceFailureStderr(summary workspace.LoadSummary) []string {
	if summary.FailedRepos == 0 {
		return nil
	}
	lines := []string{fmt.Sprintf("Warning: %d repos failed to load", summary.FailedRepos)}
	for _, name := range summary.FailedRepoNames {
		lines = append(lines, "  - "+name)
	}
	return lines
}

// workspaceStderr is a workspace load's stderr as bv prints it: the notice
// that discovery chose the workspace — never printed for one `--workspace`
// named — then the load's own lines.
func (s *Session) workspaceStderr(configPath string, load []string) []string {
	if s.config.Workspace != "" {
		return load
	}
	return append([]string{"No .beads directory found; using workspace " + configPath}, load...)
}
