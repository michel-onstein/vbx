package engine

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/export"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// Static site export.
//
// Building the bundle is pure file writing, so it works anywhere. Deploying it
// is the part with a constraint: bv shells out to `gh` and `wrangler`, which
// the App Sandbox forbids exactly as it forbids `git`. GitHub deployment is
// therefore done in-process — the repository is created through the API, the
// bundle is pushed with go-git, and Pages is enabled through the API — with
// the token supplied by the caller from the Keychain.
//
// Cloudflare has no equivalent path here: its deployment is `wrangler`'s
// direct-upload protocol, and the honest answer is the command to run rather
// than a half-working reimplementation.

type siteRequest struct {
	// OutputDir is where the bundle is written. Required.
	OutputDir string `json:"output_dir"`
	Title     string `json:"title"`
	// IncludeRobotOutputs writes the JSON robot payloads beside the database.
	IncludeRobotOutputs bool `json:"include_robot_outputs"`
	// InteractiveGraph adds the standalone HTML graph.
	InteractiveGraph bool `json:"interactive_graph"`
	// GitHubWorkflow adds the Actions workflow that redeploys on push.
	GitHubWorkflow bool `json:"github_workflow"`
}

// exportSite builds a deployable static bundle.
func (s *Session) exportSite(req []byte) ([]byte, error) {
	var r siteRequest
	if len(req) == 0 {
		return nil, fmt.Errorf("export_site requires an \"output_dir\"")
	}
	if err := json.Unmarshal(req, &r); err != nil {
		return nil, err
	}
	if r.OutputDir == "" {
		return nil, fmt.Errorf("export_site requires a non-empty \"output_dir\"")
	}
	if r.Title == "" {
		r.Title = "Beads"
	}

	issues, analyzer, stats := s.snapshot()
	if analyzer == nil {
		return nil, fmt.Errorf("session has no analyzer")
	}

	if err := os.MkdirAll(r.OutputDir, 0o755); err != nil {
		return nil, fmt.Errorf("creating %s: %w", r.OutputDir, err)
	}

	// The exporter wants pointers and a flat dependency list.
	pointers := make([]*model.Issue, 0, len(issues))
	deps := []*model.Dependency{}
	for i := range issues {
		pointers = append(pointers, &issues[i])
		for _, dep := range issues[i].Dependencies {
			if dep != nil {
				deps = append(deps, dep)
			}
		}
	}

	// The full-source readiness authority, so a bead blocked only by a
	// tombstone is as ready in the export as it is everywhere else.
	triage := analysis.ComputeTriageWithOptions(
		issues, analysis.TriageOptions{Readiness: s.readinessIndex()})
	exporter := export.NewSQLiteExporter(pointers, deps, stats, &triage)
	config := export.DefaultSQLiteExportConfig()
	config.OutputDir = r.OutputDir
	config.Title = r.Title
	config.IncludeRobotOutputs = r.IncludeRobotOutputs
	exporter.Config = config

	if err := exporter.Export(r.OutputDir); err != nil {
		return nil, fmt.Errorf("exporting the database: %w", err)
	}

	warnings := []string{}
	if export.HasEmbeddedAssets() {
		if err := export.CopyEmbeddedAssets(r.OutputDir, r.Title); err != nil {
			return nil, fmt.Errorf("copying viewer assets: %w", err)
		}
	} else {
		// The database is still useful on its own, so this is a warning
		// rather than a failure — but a bundle with no viewer is not a site,
		// and saying so beats letting the user deploy an empty page.
		warnings = append(warnings,
			"this build of the engine has no embedded viewer assets; "+
				"the bundle contains data but no page to render it")
	}

	if r.InteractiveGraph {
		_, err := export.GenerateInteractiveGraphHTML(export.InteractiveGraphOptions{
			Issues:      issues,
			Stats:       stats,
			Triage:      &triage,
			Title:       r.Title,
			DataHash:    analyzer.DataHash(),
			Path:        filepath.Join(r.OutputDir, "graph.html"),
			ProjectName: r.Title,
		})
		if err != nil {
			warnings = append(warnings, "interactive graph: "+err.Error())
		}
	}

	if r.GitHubWorkflow {
		if err := export.AddGitHubWorkflowToBundle(r.OutputDir); err != nil {
			warnings = append(warnings, "github workflow: "+err.Error())
		}
		if err := export.GenerateHeadersFile(r.OutputDir); err != nil {
			warnings = append(warnings, "headers file: "+err.Error())
		}
	}

	files, total := bundleContents(r.OutputDir)
	return json.Marshal(map[string]any{
		"output_dir":        r.OutputDir,
		"title":             r.Title,
		"issue_count":       len(issues),
		"files":             files,
		"total_bytes":       total,
		"warnings":          warnings,
		"suggested_repo":    export.SuggestRepoName(r.OutputDir),
		"suggested_project": export.SuggestProjectName(r.OutputDir),
	})
}

// bundleFile is one file in the built bundle.
type bundleFile struct {
	Path  string `json:"path"`
	Bytes int64  `json:"bytes"`
}

// bundleContents lists what was written, largest first.
//
// Size matters here in a way it usually does not: the bundle is going to be
// pushed to a host with limits, and a 200 MB database is worth seeing before
// the deploy fails rather than after.
func bundleContents(dir string) ([]bundleFile, int64) {
	files := []bundleFile{}
	var total int64

	_ = filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return nil
		}
		info, statErr := entry.Info()
		if statErr != nil {
			return nil
		}
		rel, relErr := filepath.Rel(dir, path)
		if relErr != nil {
			rel = path
		}
		files = append(files, bundleFile{Path: rel, Bytes: info.Size()})
		total += info.Size()
		return nil
	})

	sort.SliceStable(files, func(i, j int) bool {
		if files[i].Bytes != files[j].Bytes {
			return files[i].Bytes > files[j].Bytes
		}
		return files[i].Path < files[j].Path
	})
	return files, total
}

// previewRequest starts or stops the local preview server.
type previewRequest struct {
	BundlePath string `json:"bundle_path"`
	Port       int    `json:"port"`
}

// previewSite serves a built bundle locally.
//
// The server runs in-process, so no subprocess is involved and it works under
// the sandbox. It is started detached; the session owns it until close.
func (s *Session) previewSite(req []byte) ([]byte, error) {
	var r previewRequest
	if len(req) == 0 {
		return nil, fmt.Errorf("export_preview requires a \"bundle_path\"")
	}
	if err := json.Unmarshal(req, &r); err != nil {
		return nil, err
	}
	if r.BundlePath == "" {
		return nil, fmt.Errorf("export_preview requires a non-empty \"bundle_path\"")
	}
	if _, err := os.Stat(filepath.Join(r.BundlePath, "index.html")); err != nil {
		return nil, fmt.Errorf("%s does not look like a built bundle", r.BundlePath)
	}

	port := r.Port
	if port == 0 {
		found, err := export.FindAvailablePort(8787, 8887)
		if err != nil {
			return nil, fmt.Errorf("finding a free port: %w", err)
		}
		port = found
	}

	config := export.PreviewConfig{
		BundlePath:  r.BundlePath,
		Port:        port,
		OpenBrowser: false,
		Quiet:       true,
		LiveReload:  true,
	}

	// Started on its own goroutine: the server blocks, and the caller wants
	// the URL back rather than the call never returning.
	started := make(chan error, 1)
	go func() { started <- export.StartPreviewWithConfig(config) }()

	select {
	case err := <-started:
		// Returning this fast means it failed to bind.
		return nil, fmt.Errorf("starting the preview server: %w", err)
	case <-time.After(300 * time.Millisecond):
	}

	return json.Marshal(map[string]any{
		"url":         fmt.Sprintf("http://localhost:%d", port),
		"port":        port,
		"bundle_path": r.BundlePath,
	})
}
