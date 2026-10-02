package engine

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/Dicklesworthstone/beads_viewer/pkg/loader"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	"github.com/Dicklesworthstone/beads_viewer/pkg/workspace"
)

// A port of bv's multi-repository loader, `workspace.AggregateLoader`, with
// the two places it reaches a tracker made the caller's choice.
//
// bv's loader spawns trackers as part of reading: `loadSingleRepo` binds each
// repository's beads to their origin (`loader.AttachIssueOrigins`, which runs
// `br update --help`), and for a Dolt-backed repository it first refreshes the
// export with `bd export`. Neither is optional in v0.25.2, and the App Sandbox
// forbids both — so the app cannot call it. See ADR-020 and BUGS.md,
// 2026-10-01.
//
// Everything else is bv's, line for line: repository enumeration and
// discovery, path resolution, the tombstone split, namespacing and the
// collision check. Each piece is built from bv's exported loader and
// workspace functions; only the unexported orchestration is copied.
// `TestWorkspaceLoaderMatchesBV` holds the port to bv's own loader on the same
// inputs, so an upgrade that changes bv's behaviour fails there rather than
// drifting here. bv's stderr diagnostics are not printed: each goes to the
// reader's warn instead, at the point bv prints it, so vbx-cli can print the
// same lines where bv would (vbx-1l6) and the app stays silent.

// workspaceReader is what a workspace load may do beyond reading files.
type workspaceReader struct {
	// attach binds one repository's beads to their origin, before their ids
	// are namespaced — bv's position for `loader.AttachIssueOrigins`.
	attach func(issues []model.Issue, sourcePath string, complete bool)
	// refreshBDExport runs `bd export` for a Dolt-backed repository before
	// reading its compatibility JSONL, as bv's loader always does.
	refreshBDExport bool
	// warn receives each warning bv prints to stderr outside robot mode, at
	// the point it prints it: a member's source fallback and its parse
	// warnings, every one rather than the ten a LoadResult keeps. Nil
	// discards them.
	warn func(message string)
}

// workspaceReader returns what this session's workspace load may do. Only
// vbx-cli reaches a tracker; the app binds its explanatory origin instead, and
// reads a Dolt repository's export as it stands.
func (s *Session) workspaceReader() workspaceReader {
	if s.config.LiveTrackerActions {
		return workspaceReader{
			attach: func(issues []model.Issue, source string, complete bool) {
				attachLiveOrigins(issues, source, complete)
			},
			refreshBDExport: true,
		}
	}
	return workspaceReader{
		attach: func(issues []model.Issue, _ string, _ bool) { bindAppOrigins(issues) },
	}
}

// loadAllFromConfig is bv's `workspace.LoadAllFromConfig`.
func loadAllFromConfig(configPath string, reader workspaceReader) ([]model.Issue, []workspace.LoadResult, error) {
	config, err := workspace.LoadConfig(configPath)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to load workspace config: %w", err)
	}
	// .bv/workspace.yaml -> workspace root
	l := &aggregateLoader{config: config, root: filepath.Dir(filepath.Dir(configPath)), reader: reader}
	return l.loadAll()
}

// aggregateLoader is bv's `workspace.AggregateLoader`.
type aggregateLoader struct {
	config *workspace.Config
	root   string
	reader workspaceReader
}

// warn passes on a warning bv would print to stderr.
func (l *aggregateLoader) warn(message string) {
	if l.reader.warn != nil {
		l.reader.warn(message)
	}
}

// loadAll is `AggregateLoader.LoadAll`. Repositories load one after another
// rather than bv's 32-wide errgroup: results are kept in repository order
// either way, so only the wall-clock time differs.
func (l *aggregateLoader) loadAll() ([]model.Issue, []workspace.LoadResult, error) {
	if l.config == nil {
		return nil, nil, fmt.Errorf("workspace config is nil")
	}
	repos, err := l.getRepos()
	if err != nil {
		return nil, nil, err
	}

	known := knownRepoPrefixes(repos)
	results := make([]workspace.LoadResult, len(repos))
	for i, repo := range repos {
		if !repo.IsEnabled() {
			results[i] = workspace.LoadResult{
				RepoName: repo.GetName(), Prefix: repo.GetPrefix(), RepoPath: repo.Path, Disabled: true,
			}
			continue
		}
		results[i] = l.loadSingleRepo(repo, known)
	}

	var allIssues []model.Issue
	var failedRepoNames []string
	var firstRepoErr error
	enabledCount := 0
	issueSource := make(map[string]string)
	collisionSources := make(map[string]map[string]bool)
	for _, result := range results {
		if result.Disabled {
			continue
		}
		enabledCount++
		if result.Error != nil {
			failedRepoNames = append(failedRepoNames, result.RepoName)
			if firstRepoErr == nil {
				firstRepoErr = result.Error
			}
			continue
		}
		identity := workspaceLoadResultIdentity(result)
		record := func(id string) {
			if previous, exists := issueSource[id]; exists {
				if collisionSources[id] == nil {
					collisionSources[id] = map[string]bool{previous: true}
				}
				collisionSources[id][identity] = true
			} else {
				issueSource[id] = identity
			}
		}
		for _, issue := range result.Issues {
			record(issue.ID)
		}
		for _, id := range result.TombstoneIDs {
			record(id)
		}
		allIssues = append(allIssues, result.Issues...)
	}

	if enabledCount == 0 {
		return nil, results, fmt.Errorf("no enabled repositories in workspace")
	}
	if len(failedRepoNames) == enabledCount {
		return nil, results, fmt.Errorf("all %d enabled repositories failed to load (%s): %w",
			enabledCount, strings.Join(failedRepoNames, ", "), firstRepoErr)
	}
	if len(collisionSources) > 0 {
		ids := make([]string, 0, len(collisionSources))
		for id := range collisionSources {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		details := make([]string, 0, len(ids))
		for _, id := range ids {
			sources := make([]string, 0, len(collisionSources[id]))
			for source := range collisionSources[id] {
				sources = append(sources, source)
			}
			sort.Strings(sources)
			details = append(details, fmt.Sprintf("%q from %s", id, strings.Join(sources, ", ")))
		}
		return nil, results, fmt.Errorf("workspace namespacing produced duplicate issue IDs: %s",
			strings.Join(details, "; "))
	}
	return allIssues, results, nil
}

// getRepos is `AggregateLoader.getRepos`: configured then discovered
// repositories, disabled entries included so their paths still suppress
// discovery of the same repository.
func (l *aggregateLoader) getRepos() ([]workspace.RepoConfig, error) {
	var repos []workspace.RepoConfig
	seenPaths := make(map[string]bool)
	seenPrefixes := make(map[string]bool)
	seenSourceRepos := make(map[string]bool)

	add := func(repo workspace.RepoConfig) error {
		repo = l.applyDefaults(repo)
		abs, err := filepath.Abs(l.resolveRepoPath(repo.Path))
		if err != nil {
			return fmt.Errorf("resolve repo path %q: %w", repo.Path, err)
		}
		pathKey := filepath.Clean(abs)
		if seenPaths[pathKey] {
			return nil
		}
		seenPaths[pathKey] = true

		if !repo.IsEnabled() {
			repos = append(repos, repo)
			return nil
		}
		prefixKey := strings.ToLower(repo.GetPrefix())
		if seenPrefixes[prefixKey] {
			return fmt.Errorf("duplicate workspace prefix %q", repo.GetPrefix())
		}
		sourceRepo := sourceRepoKeyFromPrefix(prefixKey)
		if sourceRepo == "" {
			return fmt.Errorf("workspace prefix %q has no usable source repository key", repo.GetPrefix())
		}
		if seenSourceRepos[sourceRepo] {
			return fmt.Errorf("workspace prefix %q duplicates normalized source repository key %q",
				repo.GetPrefix(), sourceRepo)
		}
		seenPrefixes[prefixKey] = true
		seenSourceRepos[sourceRepo] = true
		repos = append(repos, repo)
		return nil
	}

	for _, repo := range l.config.Repos {
		if err := add(repo); err != nil {
			return nil, err
		}
	}
	if l.config.Discovery.Enabled {
		discovered, err := l.discoverRepos()
		if err != nil {
			return nil, err
		}
		for _, repo := range discovered {
			if err := add(repo); err != nil {
				return nil, err
			}
		}
	}
	return repos, nil
}

func (l *aggregateLoader) applyDefaults(repo workspace.RepoConfig) workspace.RepoConfig {
	if repo.BeadsPath == "" && l.config.Defaults.BeadsPath != "" {
		repo.BeadsPath = l.config.Defaults.BeadsPath
	}
	return repo
}

func (l *aggregateLoader) defaultBeadsPath() string {
	if l.config.Defaults.BeadsPath != "" {
		return l.config.Defaults.BeadsPath
	}
	return ".beads"
}

func (l *aggregateLoader) resolveRepoPath(repoPath string) string {
	if !filepath.IsAbs(repoPath) {
		repoPath = filepath.Join(l.root, repoPath)
	}
	return repoPath
}

// discoverRepos is `AggregateLoader.discoverRepos`.
func (l *aggregateLoader) discoverRepos() ([]workspace.RepoConfig, error) {
	root := l.root
	if root == "" {
		root = "."
	}
	rootAbs, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("resolve workspace root %q: %w", root, err)
	}

	patterns := l.config.Discovery.Patterns
	if len(patterns) == 0 {
		patterns = workspace.DefaultDiscoveryPatterns()
	}
	excludes := l.config.Discovery.Exclude
	if len(excludes) == 0 {
		excludes = workspace.DefaultExcludePatterns()
	}
	maxDepth := l.config.Discovery.MaxDepth
	if maxDepth == 0 {
		maxDepth = 2
	}

	var repos []workspace.RepoConfig
	seen := make(map[string]bool)
	for _, pattern := range patterns {
		matches, err := filepath.Glob(filepath.Join(rootAbs, filepath.FromSlash(pattern)))
		if err != nil {
			return nil, fmt.Errorf("invalid discovery pattern %q: %w", pattern, err)
		}
		sort.Strings(matches)

		for _, match := range matches {
			info, err := os.Stat(match)
			if os.IsNotExist(err) {
				continue
			}
			if err != nil {
				return nil, fmt.Errorf("inspect discovered repository %q: %w", match, err)
			}
			if !info.IsDir() {
				continue
			}
			rel, err := filepath.Rel(rootAbs, match)
			if err != nil {
				return nil, fmt.Errorf("resolve discovered repo %q: %w", match, err)
			}
			rel = filepath.ToSlash(filepath.Clean(rel))
			if discoveryDepth(rel) > maxDepth || discoveryExcluded(rel, excludes) || seen[rel] {
				continue
			}

			beadsPath := l.defaultBeadsPath()
			beadsDir, err := loader.ResolveBeadsDir(filepath.Join(match, beadsPath))
			if err != nil {
				return nil, fmt.Errorf("resolve tracker for discovered repository %q: %w", match, err)
			}
			beadsInfo, err := os.Stat(beadsDir)
			if os.IsNotExist(err) {
				continue
			}
			if err != nil {
				return nil, fmt.Errorf("inspect tracker for discovered repository %q: %w", match, err)
			}
			if !beadsInfo.IsDir() {
				continue
			}
			// A Dolt-native tracker is discoverable before its export exists;
			// any other needs a selectable issue file.
			if !loader.IsBDWorkspace(beadsDir) {
				if _, err := loader.FindJSONLPath(beadsDir); err != nil {
					continue
				}
			}
			repos = append(repos, workspace.RepoConfig{Path: rel, BeadsPath: beadsPath})
			seen[rel] = true
		}
	}
	return repos, nil
}

func discoveryDepth(rel string) int {
	if rel == "" || rel == "." {
		return 0
	}
	return len(strings.Split(filepath.ToSlash(rel), "/"))
}

func discoveryExcluded(rel string, excludes []string) bool {
	rel = filepath.ToSlash(filepath.Clean(rel))
	base := filepath.Base(rel)
	parts := strings.Split(rel, "/")
	for _, raw := range excludes {
		pattern := strings.TrimSpace(raw)
		if pattern == "" {
			continue
		}
		pattern = filepath.ToSlash(filepath.Clean(pattern))
		if pattern == rel || pattern == base {
			return true
		}
		if ok, _ := filepath.Match(filepath.FromSlash(pattern), filepath.FromSlash(rel)); ok {
			return true
		}
		if ok, _ := filepath.Match(filepath.FromSlash(pattern), filepath.FromSlash(base)); ok {
			return true
		}
		for _, part := range parts {
			if pattern == part {
				return true
			}
		}
	}
	return false
}

// loadSingleRepo is `AggregateLoader.loadSingleRepo`, with the bd refresh and
// the origin binding taken from the reader.
func (l *aggregateLoader) loadSingleRepo(repo workspace.RepoConfig, known map[string]bool) workspace.LoadResult {
	repo = l.applyDefaults(repo)
	repoPath := l.resolveRepoPath(repo.Path)
	result := workspace.LoadResult{
		RepoName: repo.GetName(), Prefix: repo.GetPrefix(), RepoPath: repo.Path,
		SourcePath: filepath.Join(repoPath, repo.GetBeadsPath()),
	}

	beadsDir, err := loader.ResolveBeadsDir(filepath.Join(repoPath, repo.GetBeadsPath()))
	if err != nil {
		result.Error = fmt.Errorf("failed to resolve tracker for %s: %w", repo.GetName(), err)
		return result
	}
	warnSourceFallback := func(message string) {
		message = strings.TrimSpace(message)
		if message == "" {
			return
		}
		result.WarningCount++
		if len(result.AuthorityWarnings) < 10 {
			result.AuthorityWarnings = append(result.AuthorityWarnings, message)
		}
		l.warn(message)
	}
	jsonlPath, err := loader.PrepareBeadsDirForRead(beadsDir, l.reader.refreshBDExport, warnSourceFallback)
	if err != nil {
		result.SourcePath = beadsDir
		result.Error = fmt.Errorf("failed to load issues from %s: %w", repo.GetName(), err)
		return result
	}
	result.SourcePath = jsonlPath
	options := loader.ParseOptions{Stats: &result.ParseStats}
	options.WarningHandler = func(message string) {
		result.WarningCount++
		if len(result.ParseWarnings) < 10 {
			result.ParseWarnings = append(result.ParseWarnings, message)
		}
		l.warn(message)
	}
	issues, err := loader.LoadIssuesFromFileWithOptions(jsonlPath, options)
	if err != nil {
		result.Error = fmt.Errorf("failed to load issues from %s: %w", repo.GetName(), err)
		return result
	}
	if result.ParseStats.Valid == 0 && result.ParseStats.Errors+result.ParseStats.Skipped > 0 {
		result.Error = fmt.Errorf(
			"failed to load issues from %s: no issue records (%d non-issue/error lines, 0 valid issues)",
			repo.GetName(), result.ParseStats.Errors+result.ParseStats.Skipped)
		return result
	}

	// Local references resolve before tombstones are filtered: a deleted local
	// id that resembles another repository's prefix is still local.
	localIDs := make(map[string]bool, len(issues))
	for _, issue := range issues {
		localIDs[issue.ID] = true
	}
	prefix := repo.GetPrefix()
	var tombstoneIDs []string
	visible := issues[:0]
	for i := range issues {
		if issues[i].Status.IsTombstone() {
			tombstoneIDs = append(tombstoneIDs, workspace.QualifyID(issues[i].ID, prefix))
		} else {
			visible = append(visible, issues[i])
		}
	}
	clear(issues[len(visible):])
	issues = visible

	l.reader.attach(issues, jsonlPath, result.ParseStats.Errors == 0 && len(result.AuthorityWarnings) == 0)
	result.Issues = namespaceIssues(issues, prefix, localIDs, known)
	result.TombstoneIDs = tombstoneIDs
	return result
}

func workspaceLoadResultIdentity(result workspace.LoadResult) string {
	if strings.TrimSpace(result.RepoPath) != "" {
		return fmt.Sprintf("%q (path %q)", result.RepoName, result.RepoPath)
	}
	return fmt.Sprintf("%q", result.RepoName)
}

func knownRepoPrefixes(repos []workspace.RepoConfig) map[string]bool {
	prefixes := make(map[string]bool, len(repos))
	for _, repo := range repos {
		if prefix := repo.GetPrefix(); prefix != "" {
			prefixes[prefix] = true
		}
	}
	return prefixes
}

func sourceRepoKeyFromPrefix(prefix string) string {
	return strings.ToLower(strings.TrimRight(strings.TrimSpace(prefix), "-:_"))
}

// namespaceIssues is `AggregateLoader.namespaceIssues`: the prefix on every
// id, dependency and comment reference, in place.
func namespaceIssues(issues []model.Issue, prefix string, localIDs, known map[string]bool) []model.Issue {
	sourceRepo := sourceRepoKeyFromPrefix(prefix)
	for i := range issues {
		issue := &issues[i]
		issue.ID = workspace.QualifyID(issue.ID, prefix)
		issue.SourceRepo = sourceRepo
		for _, dep := range issue.Dependencies {
			if dep == nil {
				continue
			}
			dep.IssueID = workspace.QualifyID(dep.IssueID, prefix)
			// A local id is qualified; one already carrying a known prefix is
			// an external reference; anything else is assumed local.
			if localIDs[dep.DependsOnID] || !hasKnownPrefix(dep.DependsOnID, known) {
				dep.DependsOnID = workspace.QualifyID(dep.DependsOnID, prefix)
			}
		}
		for _, comment := range issue.Comments {
			if comment != nil {
				comment.IssueID = workspace.QualifyID(comment.IssueID, prefix)
			}
		}
	}
	return issues
}

func hasKnownPrefix(id string, known map[string]bool) bool {
	for prefix := range known {
		if len(id) > len(prefix) && id[:len(prefix)] == prefix {
			return true
		}
	}
	return false
}
