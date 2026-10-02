package engine

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	"github.com/Dicklesworthstone/beads_viewer/pkg/workspace"
)

// Multi-repository workspaces.
//
// A `.bv/workspace.yaml` aggregates several repositories into one graph. bv's
// loader does the work — including namespacing each repo's ids by its prefix —
// through vbx's port of it (workspace_loader.go), which differs only in never
// spawning a tracker from the app. This is bookkeeping and reporting which repo
// a bead came from.
//
// The namespacing matters more than it looks: two repositories can each hold a
// `vbx-1`, and without a prefix one would silently overwrite the other in
// every id-keyed map in the system.

// repoLoad records how one repository fared.
type repoLoad struct {
	Name       string `json:"name"`
	Prefix     string `json:"prefix"`
	IssueCount int    `json:"issue_count"`
	Error      string `json:"error,omitempty"`
}

// findWorkspaceConfig looks for a workspace configuration at or above path.
//
// Returns "" when there is none, which is the ordinary single-repository case
// rather than a failure.
func findWorkspaceConfig(path string) string {
	dir := path
	if info, err := os.Stat(path); err == nil && !info.IsDir() {
		dir = filepath.Dir(path)
	}
	found, err := workspace.FindWorkspaceConfig(dir)
	if err != nil {
		return ""
	}
	return found
}

// loadWorkspace aggregates every repository the configuration names.
//
// The workspace loader drops tombstone records itself and reports their
// namespaced ids instead; those come back as tombstoneIDs so a deleted blocker
// still counts as resolved, exactly as bv's own workspace mode treats it. The
// loader is vbx's port of bv's, because bv's spawns trackers — see
// workspace_loader.go.
func loadWorkspace(configPath string, reader workspaceReader) (
	issues []model.Issue, loads []repoLoad, warnings []string, tombstoneIDs []string,
	watchDirs []string, err error,
) {
	issues, results, err := loadAllFromConfig(configPath, reader)
	if err != nil {
		return nil, nil, nil, nil, nil, fmt.Errorf("loading workspace %s: %w", configPath, err)
	}

	loads = make([]repoLoad, 0, len(results))
	for _, result := range results {
		if result.Error == nil {
			tombstoneIDs = append(tombstoneIDs, result.TombstoneIDs...)
		}
		load := repoLoad{
			Name:       result.RepoName,
			Prefix:     result.Prefix,
			IssueCount: len(result.Issues),
		}
		if result.Error != nil {
			// A repository that fails to load is reported rather than
			// aborting the whole workspace: the others are still usable, and
			// silently dropping one would make its beads look closed.
			load.Error = result.Error.Error()
			warnings = append(warnings,
				fmt.Sprintf("%s: %v", result.RepoName, result.Error))
		}
		loads = append(loads, load)
	}

	sort.SliceStable(loads, func(i, j int) bool { return loads[i].Name < loads[j].Name })
	return issues, loads, warnings, tombstoneIDs, workspaceWatchDirs(configPath, results), nil
}

// workspaceWatchDirs lists every directory whose contents feed a workspace
// session, for the app's file watch (vbx-zot).
//
// The session's source is `.bv/workspace.yaml`, and a watch on that file's
// directory alone sees a membership change but never a bead: every member's
// data lives in its own repository. So the list is `.bv` itself, the root
// `.beads` that feedback is read from, and each enabled member's beads
// directory — both the one the data was actually read from and the configured
// one, which differ when a redirect is followed.
//
// Only directories that exist are listed: a watch on a missing path never
// fires. A member with no beads directory at all is watched at its repository
// root instead, so creating one is noticed. The order is stable and duplicates
// are dropped, so a caller can compare two lists to decide whether a watch
// needs re-establishing.
func workspaceWatchDirs(configPath string, results []workspace.LoadResult) []string {
	root := filepath.Dir(filepath.Dir(configPath))
	seen := map[string]bool{}
	dirs := []string{}
	add := func(dir string) bool {
		if dir == "" {
			return false
		}
		dir = filepath.Clean(dir)
		info, err := os.Stat(dir)
		if err != nil || !info.IsDir() {
			return false
		}
		if !seen[dir] {
			seen[dir] = true
			dirs = append(dirs, dir)
		}
		return true
	}

	add(filepath.Dir(configPath))
	add(feedbackDir(configPath, "workspace"))
	for _, result := range results {
		if result.Disabled {
			continue
		}
		repoPath := result.RepoPath
		if !filepath.IsAbs(repoPath) {
			repoPath = filepath.Join(root, repoPath)
		}
		watched := false
		if source := result.SourcePath; source != "" {
			if info, err := os.Stat(source); err == nil && !info.IsDir() {
				source = filepath.Dir(source)
			}
			watched = add(source)
		}
		// The configured directory, when the data came from elsewhere: the
		// redirect that points away from it lives here.
		if add(filepath.Join(repoPath, ".beads")) {
			watched = true
		}
		if !watched {
			add(repoPath)
		}
	}
	return dirs
}

// loadWorkspaceSession loads every repository the configuration names and
// analyses them as one graph.
func (s *Session) loadWorkspaceSession(configPath string) error {
	records, loads, warnings, tombstoneIDs, watchDirs, err := loadWorkspace(configPath, s.workspaceReader())
	if err != nil {
		return err
	}

	issues, readiness := visibleIssues(records), readinessAuthority(records, tombstoneIDs)
	analyzer, stats := s.analyse(issues, readiness, nil)
	s.refreshFeedback(configPath, "workspace")

	s.mu.Lock()
	defer s.mu.Unlock()
	// The configuration file stands in for the source: it is what was read,
	// and it is what the watcher should follow.
	s.source, s.kind, s.warnings = configPath, "workspace", warnings
	s.workspacePath, s.repoLoads, s.watchDirs = configPath, loads, watchDirs
	s.issues, s.records, s.readiness = issues, records, readiness
	s.tombstoneIDs = tombstoneIDs
	s.analyzer, s.stats = analyzer, stats
	s.complete = len(warnings) == 0
	s.loadedAt = timeNow()
	return nil
}

// reloadWorkspace re-aggregates every repository, gated on the content hash
// exactly as the single-repository path is.
func (s *Session) reloadWorkspace(configPath string) ([]byte, error) {
	records, loads, warnings, tombstoneIDs, watchDirs, err := loadWorkspace(configPath, s.workspaceReader())
	if err != nil {
		return nil, err
	}

	newHash := analysis.ComputeDataHash(readinessInput(records, tombstoneIDs))
	s.mu.RLock()
	var oldHash string
	if s.analyzer != nil {
		oldHash = analysis.ComputeDataHash(readinessInput(s.records, s.tombstoneIDs))
	}
	s.mu.RUnlock()

	// As in the single-repository reload: feedback is outside the hash.
	feedbackChanged := s.refreshFeedback(configPath, "workspace")
	if newHash == oldHash && oldHash != "" {
		// Membership can change without the bead set changing — a member with
		// no beads yet — and the watch must follow it either way, so the
		// directories are kept current even when nothing is re-analysed.
		s.mu.Lock()
		s.repoLoads, s.watchDirs = loads, watchDirs
		s.mu.Unlock()
		payload, err := s.info()
		if err != nil {
			return nil, err
		}
		return withChangedFlag(payload, feedbackChanged)
	}

	issues, readiness := visibleIssues(records), readinessAuthority(records, tombstoneIDs)
	analyzer, stats := s.analyse(issues, readiness, nil)

	s.mu.Lock()
	s.source, s.kind, s.warnings = configPath, "workspace", warnings
	s.workspacePath, s.repoLoads, s.watchDirs = configPath, loads, watchDirs
	s.issues, s.records, s.readiness = issues, records, readiness
	s.tombstoneIDs = tombstoneIDs
	s.analyzer, s.stats = analyzer, stats
	s.complete = len(warnings) == 0
	s.loadedAt = timeNow()
	s.mu.Unlock()

	s.invalidateHistory()

	payload, err := s.info()
	if err != nil {
		return nil, err
	}
	return withChangedFlag(payload, true)
}

// repos reports the repositories in the open workspace.
func (s *Session) repos() ([]byte, error) {
	s.mu.RLock()
	loads, configPath, issues := s.repoLoads, s.workspacePath, s.issues
	s.mu.RUnlock()

	if configPath == "" {
		// A single-repository workspace is not an error; it simply has one
		// repo, and saying so beats an empty list the UI has to interpret.
		return json.Marshal(map[string]any{
			"is_workspace":     false,
			"repos":            []repoLoad{},
			"cross_repo_edges": []crossRepoEdge{},
		})
	}

	return json.Marshal(map[string]any{
		"is_workspace":     true,
		"config_path":      configPath,
		"repos":            loads,
		"cross_repo_edges": crossRepoEdges(issues, loads),
	})
}

// crossRepoEdge is a dependency that leaves its repository.
type crossRepoEdge struct {
	From     string `json:"from"`
	To       string `json:"to"`
	FromRepo string `json:"from_repo"`
	ToRepo   string `json:"to_repo"`
	Type     string `json:"type"`
}

// crossRepoEdges finds dependencies that cross a repository boundary.
//
// These are the interesting ones in a multi-repo workspace: they are the
// coordination cost, and they are invisible from inside either repository.
func crossRepoEdges(issues []model.Issue, loads []repoLoad) []crossRepoEdge {
	prefixes := make([]repoLoad, 0, len(loads))
	for _, load := range loads {
		if load.Prefix != "" {
			prefixes = append(prefixes, load)
		}
	}
	// Longest prefix first, so `api-v2-` wins over `api-` for `api-v2-3`.
	sort.SliceStable(prefixes, func(i, j int) bool {
		return len(prefixes[i].Prefix) > len(prefixes[j].Prefix)
	})

	repoOf := func(id string) string {
		for _, load := range prefixes {
			if strings.HasPrefix(id, load.Prefix) {
				return load.Name
			}
		}
		return ""
	}

	known := make(map[string]bool, len(issues))
	for _, issue := range issues {
		known[issue.ID] = true
	}

	edges := []crossRepoEdge{}
	for _, issue := range issues {
		from := repoOf(issue.ID)
		for _, dep := range issue.Dependencies {
			if dep == nil || !known[dep.DependsOnID] {
				continue
			}
			to := repoOf(dep.DependsOnID)
			if from == "" || to == "" || from == to {
				continue
			}
			edges = append(edges, crossRepoEdge{
				From: issue.ID, To: dep.DependsOnID,
				FromRepo: from, ToRepo: to, Type: string(dep.Type),
			})
		}
	}

	sort.SliceStable(edges, func(i, j int) bool {
		if edges[i].From != edges[j].From {
			return edges[i].From < edges[j].From
		}
		return edges[i].To < edges[j].To
	})
	return edges
}
