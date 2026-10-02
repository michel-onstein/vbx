// Package engine wraps bv's analysis engine in a session model with a
// JSON request/response vocabulary.
//
// The vocabulary deliberately mirrors bv's robot protocol method names, so a
// new bv capability becomes reachable from vbx without changing the C ABI.
// Everything here is plain Go with no cgo, so it is unit-testable directly;
// the cgo layer in ../cbridge is a thin marshalling shim over Call.
package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	bvcorrelation "github.com/Dicklesworthstone/beads_viewer/pkg/correlation"
	"github.com/Dicklesworthstone/beads_viewer/pkg/loader"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	"github.com/qjam/vbx/engine/correlation"
)

// OpenConfig is the payload accepted by Open.
type OpenConfig struct {
	// Path is a workspace directory, a .beads directory, or a file
	// (.jsonl or .db). Empty means the current working directory.
	Path string `json:"path"`
	// SkipPhase2 disables the expensive centrality metrics entirely.
	SkipPhase2 bool `json:"skip_phase2"`
	// LiveTrackerActions binds each bead to the live tracker that supplied
	// it, so triage and robot-next carry runnable `br show` and
	// `br update --claim` commands, exactly as bv 0.25 does. Resolving that
	// route runs `br update --help` as a subprocess, which the App Sandbox
	// forbids, so only vbx-cli sets it. Off — the app's setting — every
	// bead's actions say why they are unavailable instead. See ADR-020.
	LiveTrackerActions bool `json:"live_tracker_actions"`
	// ExportHooks runs the project's .bv/hooks.yaml around a report written
	// to disk by export_report, as bv's --export does. A hook is a command
	// the repository configures, run through `sh -c` — a subprocess the App
	// Sandbox forbids — so only vbx-cli sets it, and only without
	// --no-hooks. Off, export_report never reads the hook file.
	ExportHooks bool `json:"export_hooks"`
	// Workspace names a workspace configuration to load as given, skipping
	// discovery — bv's --workspace, which vbx-cli's sets. Path is then not
	// read. Empty means discover from Path, by bv's precedence (ADR-026).
	Workspace string `json:"workspace,omitempty"`
	// FeedbackCommand opens the session the way bv answers --feedback-accept,
	// --feedback-ignore, --feedback-show and --feedback-reset: before it
	// discovers a workspace or reads --workspace. Workspace is ignored, Path
	// is read as a single repository, and feedback.json is the one in the
	// beads directory bv resolves for Path. A load that fails does not fail
	// the open, because bv's show and reset never load; it fails a verdict
	// instead, with bv's text (vbx-v1t). See openForFeedback.
	FeedbackCommand bool `json:"feedback_command,omitempty"`
	// FeedbackFromPath reads feedback.json the way bv's robot commands do:
	// from the beads directory bv resolves for Path, standing in for the
	// working directory — loader.GetBeadsDir("") — whichever graph the session
	// loaded. Below a workspace root that is the folder's own `.beads`, not
	// the root's. Off — the app's setting — a workspace's feedback is its
	// root's, which the app both shows and writes (vbx-15s). Only vbx-cli
	// sets it. See sessionFeedbackDir.
	FeedbackFromPath bool `json:"feedback_from_path,omitempty"`
	// IDPatterns are bv's --id-pattern values: extra bead-id regexes the
	// history's explicit-id strategy and orphan detector recognise, for ids
	// bv's built-in patterns miss — a br-minted vbx-8ou has no numeric
	// suffix. Capture group 1 is the id, else the whole match. Open refuses
	// one that does not compile, with bv's text, before anything else, as bv
	// does. vbx-cli passes its --id-pattern flags here.
	IDPatterns []string `json:"id_patterns,omitempty"`
	// IDPatternsFromPrefix adds a pattern for each id prefix the session
	// loads — `.beads/config.yaml`'s issue_prefix, or each workspace
	// member's prefix — so a commit naming any of the workspace's br-minted
	// ids is linked. bv has no such default; it is the app's, which has no
	// command line to pass --id-pattern on. vbx-cli leaves it off and
	// answers as bv does. See idpatterns.go and ADR-027.
	IDPatternsFromPrefix bool `json:"id_patterns_from_prefix,omitempty"`
}

// Session holds one loaded workspace and its analysis state.
type Session struct {
	mu sync.RWMutex

	config OpenConfig
	source string // resolved file actually read
	kind   string // "jsonl" | "sqlite"
	// issues is the analysis set: every record except tombstones, which is
	// what bv analyses. records is every decoded record, tombstones included,
	// because decoding never drops one — it is what the `issues` payload
	// returns. readiness is bv's dependency authority over records, so a
	// tombstoned blocker counts as resolved. See readiness.go and ADR-021.
	issues    []model.Issue
	records   []model.Issue
	readiness *model.ReadinessIndex
	// tombstoneIDs are deleted beads a loader reported by id alone — bv's
	// workspace loader keeps no record for them. Readiness and the reload
	// gate both include them.
	tombstoneIDs []string
	warnings     []string
	// loadStderr is what bv writes to stderr while loading the same source
	// outside robot mode, line for line. See loadstderr.go.
	loadStderr []string
	// sourceLoads is each source's parse accounting — one for a single
	// repository, one per member for a workspace — from which the robot
	// envelope's load_stats is built. See loadstats.go.
	sourceLoads []sourceLoad
	// complete is bv's claim-safety verdict on the load: every record parsed
	// and every repository loaded. A partial load can make a blocked bead
	// look ready, so no claim command is ever emitted from one.
	complete bool

	analyzer *analysis.Analyzer
	stats    *analysis.GraphStats

	// feedback is the workspace's triage feedback, `.beads/feedback.json`,
	// as bv reads it: nil when the file is absent or unreadable. Its
	// fingerprint is what the reload gate compares, so an edit to the file
	// alone still reloads. See feedback.go.
	feedback            *analysis.FeedbackData
	feedbackFingerprint string
	// feedbackWriteMu serialises the load-modify-save of a feedback write,
	// so two verdicts recorded at once cannot each overwrite the other.
	feedbackWriteMu sync.Mutex
	// feedbackCommandDir, feedbackCommandDirErr and feedbackLoadErr are set
	// only for a FeedbackCommand session: the beads directory bv resolved
	// (or why it could not), and why the issues it scores a verdict against
	// did not load. See openForFeedback.
	feedbackCommandDir    string
	feedbackCommandDirErr error
	feedbackLoadErr       error
	// pathFeedbackDir is, for a FeedbackFromPath session, the beads
	// directory bv resolves for Path — empty when it cannot be resolved,
	// where bv scores without feedback. Resolved once, at open, because the
	// resolution may run git.
	pathFeedbackDir string

	loadedAt time.Time

	// Multi-repository state. Empty workspacePath means the ordinary
	// single-repository case.
	workspacePath string
	repoLoads     []repoLoad
	// watchDirs is every directory a workspace session reads from; see
	// workspaceWatchDirs. Unused for a single repository.
	watchDirs []string

	// Correlation state, guarded separately: walking the object store is slow
	// enough that it must not hold the analysis lock, and it is only built on
	// demand because most sessions never ask for history at all.
	historyMu        sync.Mutex
	historyArtifacts map[string]*correlation.HistoryArtifact

	// clockMu serialises use of the analyzer's reference instant. The
	// analyzer outlives any one call, so each call that reads its clock sets
	// it first (see pinClock); without the lock two calls could interleave
	// one's SetNow with the other's read.
	clockMu sync.Mutex
}

// Open resolves a data source, loads it, and starts analysis.
//
// Phase 1 metrics are complete when Open returns; Phase 2 continues in the
// background and is observable through the "metrics" method's phase2_ready
// flag, matching bv's two-phase contract.
func Open(cfg OpenConfig) (*Session, error) {
	// bv compiles --id-pattern before it reads anything, and exits on the
	// first that does not compile.
	if _, err := compileIDPatterns(cfg.IDPatterns); err != nil {
		return nil, err
	}
	s := &Session{config: cfg}
	if cfg.FeedbackCommand {
		s.openForFeedback()
		return s, nil
	}
	if cfg.FeedbackFromPath {
		// bv's loadRobotFeedback swallows a failure to resolve the
		// directory and scores with the defaults; an empty directory here
		// reads no feedback.
		s.pathFeedbackDir, _ = bvFeedbackBeadsDir(cfg.Path)
	}
	if err := s.load(); err != nil {
		return nil, err
	}
	return s, nil
}

// resolveSource applies bv's discovery rules: an explicit file wins, then a
// .beads directory is searched for issues.jsonl -> beads.jsonl ->
// beads.base.jsonl, and beads.db is the fallback when no JSONL has content.
//
// stderr is the part of warnings bv itself reports — its discovery warnings,
// as the lines it prints outside robot mode (loadstderr.go). The rest are
// vbx's own, and bv prints nothing for them.
func resolveSource(path string) (src string, kind string, warnings, stderr []string, err error) {
	if path == "" {
		path, err = os.Getwd()
		if err != nil {
			return "", "", nil, nil, err
		}
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", "", nil, nil, err
	}

	info, err := os.Stat(abs)
	if err != nil {
		return "", "", nil, nil, fmt.Errorf("cannot read %s: %w", abs, err)
	}

	if !info.IsDir() {
		switch strings.ToLower(filepath.Ext(abs)) {
		case ".db", ".sqlite", ".sqlite3":
			return abs, "sqlite", nil, nil, nil
		case ".jsonl":
			return abs, "jsonl", nil, nil, nil
		default:
			// Anything else is refused rather than assumed to be JSONL.
			//
			// The default used to be "jsonl" for *any* extension, which meant
			// Probe answered yes for a README, a .swift file, even a binary
			// .icns — so the Open panel greyed out no file at all and the
			// choice failed later, in the loader. That is exactly the
			// panel/loader disagreement Probe's header says it exists to
			// design out.
			return "", "", nil, nil, fmt.Errorf(
				"%s is not bead data: expected a .jsonl or .db file, or a folder holding .beads",
				filepath.Base(abs))
		}
	}

	beadsDir := abs
	if filepath.Base(abs) != ".beads" {
		if d, derr := loader.GetBeadsDir(abs); derr == nil && d != "" {
			beadsDir = d
		} else if _, serr := os.Stat(filepath.Join(abs, ".beads")); serr == nil {
			beadsDir = filepath.Join(abs, ".beads")
		} else {
			return "", "", nil, nil, fmt.Errorf("no .beads directory found under %s", abs)
		}
	}

	// Prefer a JSONL with actual content; bv's own discovery returns the
	// first match by name, but an empty issues.jsonl next to a populated
	// beads.db is common in bd-managed repos and must not read as "no data".
	jsonlPath, jerr := loader.FindJSONLPathWithWarnings(beadsDir, func(msg string) {
		warnings = append(warnings, msg)
		stderr = append(stderr, stderrWarning(msg))
	})
	if jerr == nil && jsonlPath != "" {
		if st, serr := os.Stat(jsonlPath); serr == nil && st.Size() > 0 {
			return jsonlPath, "jsonl", warnings, stderr, nil
		}
		warnings = append(warnings,
			fmt.Sprintf("%s is empty; falling back to SQLite", filepath.Base(jsonlPath)))
	}

	db := filepath.Join(beadsDir, "beads.db")
	if _, serr := os.Stat(db); serr == nil {
		return db, "sqlite", warnings, stderr, nil
	}
	if jsonlPath != "" {
		return jsonlPath, "jsonl", warnings, stderr, nil
	}
	return "", "", warnings, stderr, fmt.Errorf("no bead data found in %s", beadsDir)
}

// phase1OnlyConfig disables every metric in bv's expensive tier, leaving
// degree, topological order and density — the values Open must return
// immediately.
func phase1OnlyConfig() analysis.AnalysisConfig {
	cfg := analysis.DefaultConfig()
	cfg.ComputePageRank = false
	cfg.ComputeBetweenness = false
	cfg.ComputeHITS = false
	cfg.ComputeEigenvector = false
	cfg.ComputeCriticalPath = false
	cfg.ComputeCycles = false
	cfg.ComputeKCore = false
	cfg.ComputeArticulation = false
	cfg.ComputeSlack = false
	return cfg
}

func (s *Session) load() error {
	// bv's precedence (ADR-026): a reachable `.beads` wins over a workspace
	// configuration found upward, and an explicit configuration over both.
	if configPath := workspaceConfigFor(s.config); configPath != "" {
		return s.loadWorkspaceSession(configPath)
	}
	_, err := s.loadSingle()
	return err
}

// loadSingle loads Path as one repository, with no workspace discovery. On
// failure it returns what bv would have printed while trying, so a caller
// that reports the failure itself can print that first.
func (s *Session) loadSingle() ([]string, error) {
	src, kind, warnings, stderr, err := resolveSource(s.config.Path)
	if err != nil {
		return stderr, err
	}

	records, read, complete, err := s.readSource(src, kind, &warnings, &stderr)
	if err != nil {
		return stderr, fmt.Errorf("loading %s: %w", src, err)
	}

	issues, readiness := visibleIssues(records), readinessAuthority(records, nil)
	an, stats := s.analyse(issues, readiness, nil)
	s.refreshFeedback(src, kind)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.source, s.kind, s.warnings, s.loadStderr = src, kind, warnings, stderr
	s.sourceLoads = []sourceLoad{read}
	s.workspacePath, s.repoLoads = "", nil
	s.issues, s.records, s.readiness = issues, records, readiness
	s.tombstoneIDs = nil
	s.analyzer, s.stats = an, stats
	s.complete = complete
	s.loadedAt = time.Now()
	return nil, nil
}

// readSource parses one resolved source and binds every bead to its origin.
//
// complete is false when any record failed to parse: bv's datasource treats
// that as incomplete source authority, and so does this. The returned
// sourceLoad is the read's parse accounting, for load_stats: bv's own
// loader's for a JSONL, and vbx's SQLite reader's for a beads.db, which drops
// and counts rows by bv's SQLite rule.
//
// A JSONL's parse warnings are added to stderr too, because bv prints them;
// a beads.db's dropped rows are not, because bv's SQLite reader only counts
// them (loadstderr.go).
func (s *Session) readSource(src, kind string, warnings, stderr *[]string) ([]model.Issue, sourceLoad, bool, error) {
	var (
		issues []model.Issue
		err    error
		parsed loader.ParseStats
		kept   warningRecorder
	)
	switch kind {
	case "sqlite":
		var dropped []string
		issues, parsed, dropped, err = LoadSQLite(src)
		for _, msg := range dropped {
			*warnings = append(*warnings, msg)
			kept.add(msg)
		}
	default:
		opts := loader.ParseOptions{
			WarningHandler: func(msg string) {
				*warnings = append(*warnings, msg)
				*stderr = append(*stderr, stderrWarning(msg))
				kept.add(msg)
			},
			Stats: &parsed,
		}
		issues, err = loader.LoadIssuesFromFileWithOptions(src, opts)
	}
	if err != nil {
		return nil, sourceLoad{}, false, err
	}
	complete := parsed.Errors == 0
	s.bindOrigins(issues, src, complete)
	return issues, sourceLoad{sourcePath: src, stats: parsed, warnings: kept.kept}, complete, nil
}

// analyse builds the analyzer and starts the metrics for one issue set.
//
// Shared by the single-repository and workspace paths so the two cannot drift
// apart on which metrics run. The graph is the visible set; readiness is the
// full-source authority, installed before analysis starts because the
// analyzer fixes its authority on first use — bv's RobotContext.Analyzer does
// the same. candidates narrows which beads readiness may offer as work — a
// label scope's core beads (scope.go); nil means every analysed bead.
func (s *Session) analyse(
	issues []model.Issue, readiness *model.ReadinessIndex, candidates map[string]bool,
) (*analysis.Analyzer, *analysis.GraphStats) {
	an := analysis.NewAnalyzer(issues)
	an.SetReadinessScope(readiness, candidates)
	if s.config.SkipPhase2 {
		// Every Phase-2 metric off. Analyze() runs them synchronously, so
		// skipping has to be expressed through the config rather than by
		// choosing the sync entry point. The resulting status entries read
		// "skipped", which is what the UI renders instead of a fake zero.
		st := an.AnalyzeWithConfig(phase1OnlyConfig())
		return an, &st
	}
	return an, an.AnalyzeAsync(context.Background())
}

// timeNow exists so the workspace path reads the same as the ordinary one.
func timeNow() time.Time { return time.Now() }

// robotNow is the clock every analysis reads: triage, priority impact, the
// plan and actionable set, label health and attention, drift alerts, ETA,
// burndown, forecast, recipes and the robot envelope.
//
// bv 0.23 onward pins all of these, so vbx does too. Matching bv means matching
// where it pins as well as that it pins: before bv 0.23 label health read the
// wall clock, and vbx followed it there.
//
// It is read on every call and never captured: the app keeps one session open
// for hours, and a "now" taken at load would freeze every staleness and
// urgency figure at the moment the workspace was opened. Wall-clock time that
// is not analysis — when the session loaded, a commit's timestamp — stays on
// time.Now().
//
// It honours SOURCE_DATE_EPOCH, which is bv's own mechanism and exists for a
// specific reason: staleness is measured from "now", so two runs a second
// apart produce slightly different scores. That is not a disagreement about
// the data, but it makes exact comparison impossible — and the parity harness
// needs exact comparison, because a tolerance wide enough to absorb the clock
// is wide enough to hide a real difference.
func robotNow() time.Time {
	seconds, ok := sourceDateEpoch()
	if !ok {
		// An unparseable value is ignored rather than treated as the epoch,
		// which would make everything look infinitely stale.
		return time.Now()
	}
	return time.Unix(seconds, 0).UTC()
}

// sourceDateEpoch reads SOURCE_DATE_EPOCH, reporting whether it is set to a
// usable value. bv's `sourceDateEpochActive` draws the same line: a blank or
// unparseable value pins nothing.
func sourceDateEpoch() (int64, bool) {
	raw := strings.TrimSpace(os.Getenv("SOURCE_DATE_EPOCH"))
	if raw == "" {
		return 0, false
	}
	seconds, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0, false
	}
	return seconds, true
}

// pinClock sets the analyzer's reference instant to robotNow() for the call
// about to use it, and returns the release for clockMu.
//
// The analyzer's own default is the wall clock at construction, which in a
// long-lived session is the load time; every method that reads it (readiness,
// the plan, recommendations, the blocker chain) must be preceded by this.
// Do any waiting — WaitForPhase2 — before calling it, not while holding it.
func (s *Session) pinClock(an *analysis.Analyzer) func() {
	s.clockMu.Lock()
	an.SetNow(robotNow())
	return s.clockMu.Unlock
}

// Close releases session state.
func (s *Session) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.issues, s.records, s.readiness = nil, nil, nil
	s.analyzer, s.stats = nil, nil
}

// Call dispatches one method by name. req may be nil or empty.
func (s *Session) Call(method string, req []byte) ([]byte, error) {
	if s.config.FeedbackCommand {
		// Opened for bv's feedback commands, which may have loaded nothing:
		// anything else would answer over an empty or absent graph.
		switch method {
		case "info", "triage_feedback", "triage_feedback_record", "triage_feedback_reset":
		default:
			return nil, fmt.Errorf("method %q is not available to a session opened for feedback", method)
		}
	}
	switch method {
	case "info":
		return s.info()
	case "issues":
		return s.issuesPayload()
	case "metrics":
		return s.metrics()
	case "wait_phase2":
		s.mu.RLock()
		st := s.stats
		s.mu.RUnlock()
		if st != nil {
			st.WaitForPhase2()
		}
		return s.metrics()
	case "compute_phase2":
		return s.computePhase2()
	case "reload":
		return s.reload()
	case "triage":
		return s.triage(req)
	case "plan":
		return s.plan(req)
	case "impact":
		return s.impact()
	case "recommendations":
		return s.recommendations()
	case "actionable":
		return s.actionable()
	case "blocker_chain":
		return s.blockerChain(req)
	case "unblocks":
		return s.unblocks(req)
	case "label_health":
		return s.labelHealth(req)
	case "label_flow":
		return s.labelFlow(req)
	case "label_attention":
		return s.labelAttention(req)
	case "eta":
		return s.eta(req)
	case "forecast":
		return s.forecast(req)
	case "graph":
		return s.graph()
	case "export_report":
		return s.exportReport(req)
	case "history":
		return s.historyPayload(req)
	case "causality":
		return s.causality(req)
	case "related":
		return s.relatedWork(req)
	case "impact_network":
		return s.impactNetwork(req)
	case "file_beads":
		return s.fileBeads(req)
	case "file_hotspots":
		return s.fileHotspots(req)
	case "file_relations":
		return s.fileRelations(req)
	case "orphans":
		return s.orphans(req)
	case "suggest":
		return s.suggest(req)
	case "priority":
		return s.priority(req)
	case "next":
		return s.next(req)
	case "insights":
		return s.insights(req)
	case "graph_export":
		return s.graphExport(req)
	case "file_impact":
		return s.fileImpact(req)
	case "probe":
		return probePayload(req)
	case "toon":
		return s.toonPayload(req)
	case "export_site":
		return s.exportSite(req)
	case "export_preview":
		return s.previewSite(req)
	case "export_deploy_github":
		return s.deployGitHub(req)
	case "export_cloudflare_hint":
		return s.cloudflareInstructions(req)
	case "repos":
		return s.repos()
	case "search":
		return s.searchIssues(req)
	case "search_presets":
		return s.searchPresets()
	case "sprint_list":
		return s.sprintList(req)
	case "sprint_show":
		return s.sprintShow(req)
	case "burndown":
		return s.burndown(req)
	case "capacity":
		return s.capacity(req)
	case "recipes":
		return s.recipes()
	case "recipe_apply":
		return s.applyRecipe(req)
	case "recipe_resolve":
		return s.resolveRecipeCall(req)
	case "recipe_save":
		return s.saveRecipe(req)
	case "recipe_delete":
		return s.deleteRecipe(req)
	case "alerts":
		return s.alerts(req)
	case "drift":
		return s.driftPayload(req)
	case "baseline_save":
		return s.saveBaseline(req)
	case "baseline_info":
		return s.baselineInfo()
	case "revisions":
		return s.revisions(req)
	case "snapshot_at":
		return s.snapshotAt(req)
	case "diff":
		return s.diffSince(req)
	case "commit_patch":
		return s.commitPatch(req)
	case "triage_feedback":
		return s.triageFeedbackShow()
	case "triage_feedback_record":
		return s.triageFeedbackRecord(req)
	case "triage_feedback_reset":
		return s.triageFeedbackReset()
	case "correlation_feedback":
		return s.correlationFeedback()
	case "correlation_confirm":
		return s.recordFeedback(req, correlation.FeedbackConfirm)
	case "correlation_reject":
		return s.recordFeedback(req, correlation.FeedbackReject)
	default:
		return nil, fmt.Errorf("unknown method %q", method)
	}
}

// snapshot returns the analysis set — tombstones excluded, as bv excludes
// them — with its analyzer and stats. Use records() for every decoded record.
func (s *Session) snapshot() ([]model.Issue, *analysis.Analyzer, *analysis.GraphStats) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.issues, s.analyzer, s.stats
}

// recordSet returns every decoded record, tombstones included.
func (s *Session) recordSet() []model.Issue {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.records
}

// readinessIndex returns bv's dependency authority over the full source.
func (s *Session) readinessIndex() *model.ReadinessIndex {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.readiness == nil {
		return model.NewReadinessIndex(s.records)
	}
	return s.readiness
}

// ---- method implementations -------------------------------------------------

type infoPayload struct {
	Source    string   `json:"source"`
	Kind      string   `json:"kind"`
	IssueCoun int      `json:"issue_count"`
	DataHash  string   `json:"data_hash"`
	Warnings  []string `json:"warnings"`
	// LoadStats is the robot envelope's load_stats — how many records the
	// load kept and dropped — present only when it dropped one. The app's
	// warnings badge states the counts from it (vbx-dv5).
	LoadStats *loadStats `json:"load_stats,omitempty"`
	// LoadStderr is what bv prints to stderr while loading the same source
	// outside robot mode, line for line — for vbx-cli's non-robot commands,
	// which print it as bv does (vbx-1l6). See loadstderr.go.
	LoadStderr []string `json:"load_stderr"`
	LoadedAt   string   `json:"loaded_at"`
	// WatchPaths is the directories the app's file watch follows: what was
	// read, and what is read alongside it. One for a single repository; for a
	// workspace, every member's beads directory as well (vbx-zot).
	WatchPaths []string `json:"watch_paths"`
	// GitWatchPaths is the git directories of a workspace's members, where a
	// commit moves a HEAD the root repository's watch cannot see. A different
	// list from WatchPaths because a commit changes no bead: it calls for the
	// uncommitted marks to be recomputed, not a reload (vbx-d1c). Empty for a
	// single repository.
	GitWatchPaths []string `json:"git_watch_paths"`
}

func (s *Session) info() ([]byte, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	hash := ""
	if s.analyzer != nil {
		hash = s.analyzer.DataHash()
	}
	w := s.warnings
	if w == nil {
		w = []string{}
	}
	stderr := s.loadStderr
	if stderr == nil {
		stderr = []string{}
	}
	return json.Marshal(infoPayload{
		Source:        s.source,
		Kind:          s.kind,
		IssueCoun:     len(s.records),
		DataHash:      hash,
		Warnings:      w,
		LoadStats:     robotLoadStats(s.sourceLoads),
		LoadStderr:    stderr,
		LoadedAt:      s.loadedAt.Format(time.RFC3339),
		WatchPaths:    s.watchPathsLocked(),
		GitWatchPaths: s.gitWatchPathsLocked(),
	})
}

// watchPathsLocked reports the directories to watch. Callers hold s.mu.
//
// A single repository's feedback.json sits beside its data (feedbackDir), so
// the source's directory covers both.
func (s *Session) watchPathsLocked() []string {
	if s.kind == "workspace" {
		if s.watchDirs == nil {
			return []string{}
		}
		return s.watchDirs
	}
	if s.source == "" {
		return []string{}
	}
	return []string{filepath.Dir(s.source)}
}

// issuesPayload returns every decoded record, tombstones included: the
// analysis leaves them out, but the record is still the user's.
func (s *Session) issuesPayload() ([]byte, error) {
	issues := s.recordSet()
	if issues == nil {
		issues = []model.Issue{}
	}
	return json.Marshal(map[string]any{"issues": issues})
}

// metricsPayload is the wire shape for GraphStats. Phase-2 maps are omitted
// entirely (not zeroed) until ready, so the client can distinguish "not
// computed yet" from "computed as zero" — the distinction bv's status flags
// exist to preserve.
type metricsPayload struct {
	NodeCount        int             `json:"node_count"`
	EdgeCount        int             `json:"edge_count"`
	Density          float64         `json:"density"`
	InDegree         map[string]int  `json:"in_degree"`
	OutDegree        map[string]int  `json:"out_degree"`
	TopologicalOrder []string        `json:"topological_order"`
	Phase2Ready      bool            `json:"phase2_ready"`
	Status           json.RawMessage `json:"status,omitempty"`

	PageRank     map[string]float64 `json:"pagerank,omitempty"`
	Betweenness  map[string]float64 `json:"betweenness,omitempty"`
	Eigenvector  map[string]float64 `json:"eigenvector,omitempty"`
	Hubs         map[string]float64 `json:"hubs,omitempty"`
	Authorities  map[string]float64 `json:"authorities,omitempty"`
	CriticalPath map[string]float64 `json:"critical_path,omitempty"`
	Slack        map[string]float64 `json:"slack,omitempty"`
	CoreNumber   map[string]int     `json:"core_number,omitempty"`
	Articulation []string           `json:"articulation,omitempty"`
	Cycles       [][]string         `json:"cycles,omitempty"`

	PageRankRank    map[string]int `json:"pagerank_rank,omitempty"`
	BetweennessRank map[string]int `json:"betweenness_rank,omitempty"`
}

// metrics is the session's GraphStats over the whole load.
//
// The payload carries bv's robot envelope at its top level, as every robot
// payload does (vbx-6su). bv's --robot-metrics reports runtime timings rather
// than graph statistics, but it carries the same envelope over the whole,
// unscoped load, and so does this.
func (s *Session) metrics() ([]byte, error) {
	v := s.wholeView()
	st := v.stats
	if st == nil {
		return nil, fmt.Errorf("session has no analysis")
	}

	p := metricsPayload{
		NodeCount:        st.NodeCount,
		EdgeCount:        st.EdgeCount,
		Density:          st.Density,
		InDegree:         st.InDegree,
		OutDegree:        st.OutDegree,
		TopologicalOrder: st.TopologicalOrder,
		Phase2Ready:      st.IsPhase2Ready(),
	}
	if p.InDegree == nil {
		p.InDegree = map[string]int{}
	}
	if p.OutDegree == nil {
		p.OutDegree = map[string]int{}
	}
	if p.TopologicalOrder == nil {
		p.TopologicalOrder = []string{}
	}

	if raw, err := json.Marshal(st.Status()); err == nil {
		p.Status = raw
	}

	if p.Phase2Ready {
		p.PageRank = st.PageRank()
		p.Betweenness = st.Betweenness()
		p.Eigenvector = st.Eigenvector()
		p.Hubs = st.Hubs()
		p.Authorities = st.Authorities()
		p.CriticalPath = st.CriticalPathScore()
		p.Slack = st.Slack()
		p.CoreNumber = st.CoreNumber()
		p.Articulation = st.ArticulationPoints()
		p.Cycles = st.Cycles()
		p.PageRankRank = st.PageRankRank()
		p.BetweennessRank = st.BetweennessRank()
	}
	return s.withEnvelope(p, v.dataHash, v.scope)
}

// reload re-reads the source and re-analyses only when the data actually
// changed.
//
// The gate is bv's own content hash over the sorted issue set, so an
// incidental touch — a `git status`, an editor's atomic save of an unrelated
// file in the same directory — costs one parse and no analysis at all. The
// response carries `changed` so the UI can skip republishing too.
func (s *Session) reload() ([]byte, error) {
	s.mu.RLock()
	workspacePath := s.workspacePath
	s.mu.RUnlock()
	if workspacePath != "" {
		return s.reloadWorkspace(workspacePath)
	}

	src, kind, warnings, stderr, err := resolveSource(s.config.Path)
	if err != nil {
		return nil, err
	}

	records, read, complete, err := s.readSource(src, kind, &warnings, &stderr)
	if err != nil {
		return nil, fmt.Errorf("reloading %s: %w", src, err)
	}

	// The gate hashes every record, not the analysis set: a change confined
	// to a tombstone changes nothing bv analyses but does change a record the
	// app holds.
	newHash := analysis.ComputeDataHash(records)

	s.mu.RLock()
	var oldHash string
	if s.analyzer != nil {
		oldHash = analysis.ComputeDataHash(s.records)
	}
	s.mu.RUnlock()

	// Feedback is not bead data, so the hash above cannot see it change; an
	// edit to feedback.json alone still reorders triage, and has to reach the
	// app as a change.
	feedbackChanged := s.refreshFeedback(src, kind)
	if newHash == oldHash && oldHash != "" {
		// A dropped record changes no record that survived, so the hash
		// cannot see one appear: a malformed line appended to the file
		// leaves the bead set as it was. The load's accounting is still kept
		// current — and reported as a change, so the app's badge follows it.
		accountingChanged := s.refreshAccounting([]sourceLoad{read}, warnings, stderr, complete)
		payload, err := s.info()
		if err != nil {
			return nil, err
		}
		return withChangedFlag(payload, feedbackChanged || accountingChanged)
	}

	issues, readiness := visibleIssues(records), readinessAuthority(records, nil)
	an, stats := s.analyse(issues, readiness, nil)

	s.mu.Lock()
	s.source, s.kind, s.warnings, s.loadStderr = src, kind, warnings, stderr
	s.sourceLoads = []sourceLoad{read}
	s.issues, s.records, s.readiness = issues, records, readiness
	s.tombstoneIDs = nil
	s.analyzer, s.stats = an, stats
	s.complete = complete
	s.loadedAt = time.Now()
	s.mu.Unlock()

	// Every correlation attribution is computed against the bead set, so a
	// changed set invalidates the whole report rather than part of it.
	s.invalidateHistory()

	payload, err := s.info()
	if err != nil {
		return nil, err
	}
	return withChangedFlag(payload, true)
}

// withChangedFlag splices a "changed" boolean into an info payload.
func withChangedFlag(payload []byte, changed bool) ([]byte, error) {
	var obj map[string]any
	if err := json.Unmarshal(payload, &obj); err != nil {
		return nil, err
	}
	obj["changed"] = changed
	return json.Marshal(obj)
}

// computePhase2 re-runs the full analysis with every metric enabled and
// blocks until it finishes.
//
// This is the escape hatch for a session opened with SkipPhase2 (or one whose
// metrics timed out): those runs leave the stats marked ready-but-skipped, so
// simply waiting again would return the same empty result forever. Callers get
// real values or a real timeout, never a silent no-op.
func (s *Session) computePhase2() ([]byte, error) {
	s.mu.RLock()
	an := s.analyzer
	s.mu.RUnlock()
	if an == nil {
		return nil, fmt.Errorf("session has no analyzer")
	}

	stats := an.AnalyzeAsync(context.Background())
	stats.WaitForPhase2()

	s.mu.Lock()
	s.stats = stats
	s.mu.Unlock()

	return s.metrics()
}

// triageHistoryLimit is how far back triage looks for staleness signal.
//
// bv's own value: its `--history-limit` defaults to 500, but the triage path
// silently rewrites 500 to 200. Matching that matters because the number of
// commits considered changes the staleness factor, and therefore the scores.
const triageHistoryLimit = 200

// triageHistoryTimeout bounds the walk. bv's default is the same.
//
// Triage must answer even when history cannot: a repository that is huge, or
// absent, degrades the ranking rather than failing it.
const triageHistoryTimeout = 10 * time.Second

// triage ranks what to work on next.
//
// The git-history enrichment is not optional garnish: bv feeds a correlation
// report into the scorer, and it moves the numbers. Skipping it would make
// vbx's ranking quietly disagree with `bv --robot-triage` on the same data,
// which is exactly the drift ADR-001 exists to prevent — and which the parity
// harness caught.
//
// A `label` in the request scopes it to the label's subgraph (scope.go): the
// ranking is computed over the subgraph and recommends only the labelled
// beads, as bv's --robot-triage --label does. A `recipe` ranks only what the
// recipe selects, as --recipe does.
func (s *Session) triage(req []byte) ([]byte, error) {
	r, err := parseTriageRequest(req)
	if err != nil {
		return nil, err
	}
	v, err := s.view(r.scopeRequest)
	if err != nil {
		return nil, err
	}
	issues := v.issues

	opts := analysis.TriageOptions{
		WaitForPhase2:  true,
		UseFastConfig:  true,
		Readiness:      s.readinessIndex(),
		CandidateIDs:   v.candidates,
		SeedDataHash:   v.seedHash(),
		NotReadyLabels: notReadyLabels(r.NotReadyLabels),
		Weights:        s.feedbackWeights(),
		RootIssueID:    r.GraphRoot,
	}

	historyStatus := "skipped"
	if hasOpenIssues(issues) {
		if gated := s.triageHistoryGate(); gated != "" {
			historyStatus = gated
		} else {
			report, status := s.triageHistory(issues)
			opts.History = report
			historyStatus = status
		}
	}

	result := analysis.ComputeTriageWithOptionsAndTime(issues, opts, robotNow())
	result.Meta.HistoryStatus = historyStatus
	if !s.claimsProven() {
		suppressUnprovenTriageClaims(&result)
	}
	// bv reports the feedback beside the triage, not inside it; vbx's triage
	// payload is the result itself, so the block sits at its top level, and
	// so does bv's robot envelope, which bv puts beside `triage` (vbx-6su).
	return s.withEnvelope(struct {
		analysis.TriageResult
		Feedback *analysis.FeedbackJSON `json:"feedback,omitempty"`
	}{result, s.feedbackBlock()}, v.dataHash, v.scope)
}

// hasOpenIssues reports whether there is anything left to triage.
//
// bv skips the history walk entirely when nothing is open, and so does this:
// paying for a commit walk to rank an empty queue is pure cost.
func hasOpenIssues(issues []model.Issue) bool {
	for _, issue := range issues {
		if issue.Status != model.StatusClosed && issue.Status != model.StatusTombstone {
			return true
		}
	}
	return false
}

// triageHistoryGate decides, before any walk, whether triage may use git
// history at all, returning the status to report when it may not and "" when
// it may.
//
// Both refusals are bv's (`handleRobotTriage` in v0.25.2), and both leave the
// history nil — so staleness is *absent* — rather than handing the scorer an
// empty report. That distinction is the whole point: given a report with no
// events for a bead, `ComputeStaleness` falls back to `updated_at` and reports
// a staleness bv never would. That is how an untracked fixture once showed
// spr-12 as 28 days stale in vbx and nothing at all in bv (vbx-8u3).
//
//   - SOURCE_DATE_EPOCH pinned: "skipped". A git walk raced against a
//     wall-clock deadline cannot produce stable bytes, which is the only
//     reason to pin the clock.
//   - The workspace directory — the one holding `.beads` — is not itself a
//     git checkout with a JSONL beads file: "error". bv checks for `.git`
//     right there and never looks further up, so a workspace nested inside
//     somebody's repository gets no history signal. vbx's object store
//     *would* find the enclosing repository, and the History view still uses
//     it; only triage's score has to agree with bv. bv omits the status in
//     this case; vbx says "error" so an absent signal never reads as a low
//     one.
func (s *Session) triageHistoryGate() string {
	if _, pinned := sourceDateEpoch(); pinned {
		return "skipped"
	}
	// An empty directory would make the check read the process's own working
	// directory instead.
	if dir := s.projectDir(); dir == "" || correlation.ValidateRepository(dir) != nil {
		return "error"
	}
	return ""
}

// triageHistory fetches the correlation report within a bounded time — bv's
// generateTriageHistoryBounded, over the triage's own issues.
//
// Returns bv's own vocabulary for what happened — "ok", "timeout" or "error" —
// which travels in the payload so a caller can tell a low staleness signal
// from an absent one.
func (s *Session) triageHistory(issues []model.Issue) (*bvcorrelation.HistoryReport, string) {
	type outcome struct {
		report *bvcorrelation.HistoryReport
		err    error
	}
	done := make(chan outcome, 1)
	go func() {
		report, err := s.triageReport(issues)
		done <- outcome{report, err}
	}()

	select {
	case result := <-done:
		if result.err != nil {
			// Not being in a git repository is the commonest reason, and it
			// is not a failure of triage.
			return nil, "error"
		}
		return result.report, "ok"
	case <-time.After(triageHistoryTimeout):
		return nil, "timeout"
	}
}

// plan is the execution plan; a `label` in the request plans the label's
// subgraph, offering only its labelled beads as work, and a `recipe` plans
// what the recipe selects (scope.go). bv nests the plan under `plan` beside
// its robot envelope; vbx returns the plan itself with the envelope at its
// top level (vbx-6su).
func (s *Session) plan(req []byte) ([]byte, error) {
	sc, err := parseScopeRequest(req)
	if err != nil {
		return nil, err
	}
	v, err := s.view(sc)
	if err != nil {
		return nil, err
	}
	an := v.analyzer
	if an == nil {
		return nil, fmt.Errorf("session has no analyzer")
	}
	defer s.pinClock(an)()
	return s.withEnvelope(an.GetExecutionPlan(), v.dataHash, v.scope)
}

func (s *Session) impact() ([]byte, error) {
	_, an, st := s.snapshot()
	if an == nil {
		return nil, fmt.Errorf("session has no analyzer")
	}
	defer s.pinClock(an)()
	scores := an.ComputeImpactScoresFromStats(st, an.Now())
	return json.Marshal(map[string]any{"scores": scores})
}

func (s *Session) recommendations() ([]byte, error) {
	_, an, _ := s.snapshot()
	if an == nil {
		return nil, fmt.Errorf("session has no analyzer")
	}
	defer s.pinClock(an)()
	return json.Marshal(map[string]any{"recommendations": an.GenerateRecommendations()})
}

// actionable reports the ready set and, beside it, the beads a defer_until
// still withholds at the same instant.
//
// `deferred` is the readiness reason the app shows on a bead: one that left
// Ready because of a deferral otherwise has no visible cause. It is read inside
// the same clock pin as the ready set, so the two cannot disagree about "now",
// and the test is bv's own IsDeferredAt — Swift formats the date and never
// decides whether it has passed. A closed bead is withheld by its status, not
// its deferral, so it is not listed.
func (s *Session) actionable() ([]byte, error) {
	issues, an, _ := s.snapshot()
	if an == nil {
		return nil, fmt.Errorf("session has no analyzer")
	}
	release := s.pinClock(an)
	items := an.GetActionableIssues()
	now := an.Now()
	release()
	ids := make([]string, 0, len(items))
	for _, it := range items {
		ids = append(ids, it.ID)
	}
	deferred := make([]string, 0)
	for _, issue := range issues {
		if issue.IsDeferredAt(now) && !issue.Status.IsClosed() && !issue.Status.IsTombstone() {
			deferred = append(deferred, issue.ID)
		}
	}
	return json.Marshal(map[string]any{"issues": items, "ids": ids, "deferred": deferred})
}

type idRequest struct {
	ID     string `json:"id"`
	Agents int    `json:"agents"`
}

func decodeID(req []byte) (idRequest, error) {
	var r idRequest
	if len(req) == 0 {
		return r, fmt.Errorf("request requires an \"id\"")
	}
	if err := json.Unmarshal(req, &r); err != nil {
		return r, err
	}
	if r.ID == "" {
		return r, fmt.Errorf("request requires a non-empty \"id\"")
	}
	return r, nil
}

func (s *Session) blockerChain(req []byte) ([]byte, error) {
	r, err := decodeID(req)
	if err != nil {
		return nil, err
	}
	// The chain is traced through the scoped set, so a blocker outside a
	// label's subgraph or a recipe's selection is not in it — bv's
	// --robot-blocker-chain reads ctx.Issues.
	v, err := s.scopedView(req)
	if err != nil {
		return nil, err
	}
	// bv traces it with a bare analyzer over those issues — no readiness
	// scope, no candidates. A scoped view's analyzer carries both, and under
	// --label graph that marked a blocker a root where bv does not, so this
	// one is built the way bv's is.
	an := analysis.NewAnalyzer(v.issues)
	an.SetNow(robotNow())
	chain := an.GetBlockerChain(r.ID)
	if chain == nil {
		// bv's words; it exits 1 rather than printing a null chain.
		return nil, fmt.Errorf("Issue not found: %s", r.ID)
	}
	// bv hashes the issues the chain was traced through, so the hash follows
	// the scope, and nests the chain under `result`. vbx keeps the chain at
	// the top level beside the envelope.
	return s.withEnvelope(chain, analysis.ComputeDataHash(v.issues), v.scope)
}

func (s *Session) unblocks(req []byte) ([]byte, error) {
	r, err := decodeID(req)
	if err != nil {
		return nil, err
	}
	_, an, _ := s.snapshot()
	if an == nil {
		return nil, fmt.Errorf("session has no analyzer")
	}
	release := s.pinClock(an)
	ids := an.ComputeUnblocks(r.ID)
	release()
	if ids == nil {
		ids = []string{}
	}
	return json.Marshal(map[string]any{"id": r.ID, "unblocks": ids})
}

// The label commands answer over the request's scope, as bv's do: under
// --label or --recipe they describe the labels of the scoped set, and the
// envelope names the scope and carries the unscoped data hash
// (ctx.Envelope() in bv). Each payload is the analysis result itself, which
// the app decodes, with the envelope keys beside its own fields.

func (s *Session) labelHealth(req []byte) ([]byte, error) {
	v, err := s.scopedView(req)
	if err != nil {
		return nil, err
	}
	cfg := analysis.DefaultLabelHealthConfig()
	return s.withEnvelope(
		analysis.ComputeAllLabelHealth(v.issues, cfg, robotNow(), v.stats), v.dataHash, v.scope)
}

func (s *Session) labelFlow(req []byte) ([]byte, error) {
	v, err := s.scopedView(req)
	if err != nil {
		return nil, err
	}
	cfg := analysis.DefaultLabelHealthConfig()
	return s.withEnvelope(analysis.ComputeCrossLabelFlow(v.issues, cfg), v.dataHash, v.scope)
}

// labelAttention ranks labels by how much attention they need.
//
// The score is a product of centrality, staleness and blocking impact divided
// by velocity, and bv returns each factor alongside the total. All four are
// passed through: a ranking without its decomposition says a label is in
// trouble without saying why, which is the part that tells you what to do.
func (s *Session) labelAttention(req []byte) ([]byte, error) {
	v, err := s.scopedView(req)
	if err != nil {
		return nil, err
	}
	cfg := analysis.DefaultLabelHealthConfig()
	return s.withEnvelope(
		analysis.ComputeLabelAttentionScores(v.issues, cfg, robotNow()), v.dataHash, v.scope)
}

func (s *Session) eta(req []byte) ([]byte, error) {
	r, err := decodeID(req)
	if err != nil {
		return nil, err
	}
	issues, _, st := s.snapshot()
	agents := r.Agents
	if agents <= 0 {
		agents = 1
	}
	est, err := analysis.EstimateETAForIssue(issues, st, r.ID, agents, robotNow())
	if err != nil {
		return nil, err
	}
	return json.Marshal(est)
}

// graphEdge is a blocking dependency edge, the only edge type that
// participates in bv's graph metrics.
type graphEdge struct {
	From string `json:"from"`
	To   string `json:"to"`
	Type string `json:"type"`
}

func (s *Session) graph() ([]byte, error) {
	issues, _, _ := s.snapshot()
	edges := make([]graphEdge, 0)
	known := make(map[string]bool, len(issues))
	for _, it := range issues {
		known[it.ID] = true
	}
	for _, it := range issues {
		for _, d := range it.Dependencies {
			if d == nil || !known[d.DependsOnID] {
				continue
			}
			edges = append(edges, graphEdge{
				From: it.ID, To: d.DependsOnID, Type: string(d.Type),
			})
		}
	}
	sort.Slice(edges, func(i, j int) bool {
		if edges[i].From != edges[j].From {
			return edges[i].From < edges[j].From
		}
		return edges[i].To < edges[j].To
	})
	return json.Marshal(map[string]any{"edges": edges})
}
