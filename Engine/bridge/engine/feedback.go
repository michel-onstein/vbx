package engine

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// Triage feedback and the not-ready label-class: the two inputs bv 0.25's
// --robot-triage and --robot-next pass to ComputeTriageWithOptionsAndTime
// beyond the beads themselves (vbx-5ba).
//
// Feedback is `.beads/feedback.json`, written by `bv --feedback-accept` and
// `--feedback-ignore` — or vbx-cli's same flags, through the methods at the
// end of this file. bv's loadRobotFeedback reads it on every scoring
// surface — triage, next and priority — and applies its adjusted factor
// weights only once analysis.MinFeedbackSamples events exist, so one stray
// verdict cannot reorder a project. Below that the weights stay the defaults,
// but triage still reports the block with `applied: false`. A missing file
// and an unparseable one both mean "no feedback": bv swallows the error and
// scores with the defaults, and so does this.
//
// The session holds the parsed file rather than reading it per call, so what
// the app shows is what was loaded, and the reload gate fingerprints it: an
// edit to feedback.json changes no bead, so a gate on the bead hash alone
// would never pick it up. The file sits beside the bead data, in the
// directory the app's file watch already follows.

// feedbackDir is the `.beads` directory whose feedback.json applies.
//
// bv reads the file from the beads directory it resolved for the current
// working directory. For a single repository that is the directory the data
// was read from. For a workspace the "source" is `.bv/workspace.yaml`, and bv
// run at the workspace root reads the root's `.beads`.
func feedbackDir(source, kind string) string {
	if source == "" {
		return ""
	}
	if kind == "workspace" {
		return filepath.Join(filepath.Dir(filepath.Dir(source)), ".beads")
	}
	return filepath.Dir(source)
}

// readFeedback loads feedback.json from dir, returning the parsed data (nil
// when there is none to apply or report) and a fingerprint of what was on
// disk, so a reload can tell whether it changed.
func readFeedback(dir string) (*analysis.FeedbackData, string) {
	if dir == "" {
		return nil, ""
	}
	raw, err := os.ReadFile(filepath.Join(dir, analysis.FeedbackFile))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, ""
	}
	if err != nil {
		return nil, "unreadable: " + err.Error()
	}
	sum := sha256.Sum256(raw)
	fingerprint := hex.EncodeToString(sum[:])

	// bv's own parser, for its normalisation: adjustments clamped to
	// [0.5, 2.0], unknown factor names ignored, stats recomputed from the
	// events rather than trusted from the file.
	fb, err := analysis.LoadFeedback(dir)
	if err != nil {
		return nil, fingerprint
	}
	return fb, fingerprint
}

// refreshFeedback re-reads the feedback for source and reports whether it
// differs from what the session held.
func (s *Session) refreshFeedback(source, kind string) bool {
	fb, fingerprint := readFeedback(feedbackDir(source, kind))
	s.mu.Lock()
	defer s.mu.Unlock()
	changed := fingerprint != s.feedbackFingerprint
	s.feedback, s.feedbackFingerprint = fb, fingerprint
	return changed
}

// feedbackWeights is the factor weights triage scores with: the feedback's,
// once there are enough samples to apply them, and otherwise nil — bv's
// "use the defaults".
func (s *Session) feedbackWeights() *analysis.Weights {
	s.mu.RLock()
	fb := s.feedback
	s.mu.RUnlock()
	if fb == nil || !fb.Applies() {
		return nil
	}
	w := fb.Weights()
	return &w
}

// feedbackBlock is triage's top-level `feedback` report, absent unless at
// least one verdict has been recorded — bv omits it for an empty history
// rather than reporting zero events.
func (s *Session) feedbackBlock() *analysis.FeedbackJSON {
	s.mu.RLock()
	fb := s.feedback
	s.mu.RUnlock()
	if fb == nil || len(fb.Events) == 0 {
		return nil
	}
	block := fb.ToJSON()
	return &block
}

// triageRequest is what triage and next accept: bv's --label scope and its
// --robot-not-ready-labels value, as written.
type triageRequest struct {
	Label          string `json:"label"`
	NotReadyLabels string `json:"not_ready_labels"`
}

func parseTriageRequest(req []byte) (triageRequest, error) {
	var r triageRequest
	if len(req) == 0 {
		return r, nil
	}
	err := json.Unmarshal(req, &r)
	return r, err
}

// notReadyLabels splits bv's comma-separated not-ready label-class: trimmed,
// empty entries dropped, nil when nothing is left — which disables the gate.
// Matching against bead labels is case-insensitive, and bv's analysis layer
// does it, so the labels are kept as written. The CLI resolves the flag
// against BV_ROBOT_NOT_READY_LABELS before it gets here, as bv's
// resolveNotReadyLabels does.
func notReadyLabels(raw string) []string {
	var labels []string
	for _, part := range strings.Split(raw, ",") {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			labels = append(labels, trimmed)
		}
	}
	return labels
}

// ---- recording feedback (vbx-rt3) ------------------------------------------
//
// bv's --feedback-accept, --feedback-ignore, --feedback-reset and
// --feedback-show, as engine methods. Every one goes through bv's exported
// FeedbackData — LoadFeedback, RecordFeedback, Reset, Save, ToJSON, Summary —
// so the smoothing, the clamping and the file format are bv's, not a copy.
//
// Each returns the structured state and `message`, the exact text bv prints
// on stdout for the same flag, so vbx-cli prints that rather than composing
// its own. An error's text is likewise bv's stderr line. bv stamps the event,
// the adjustments and updated_at from the wall clock (time.Now, not
// SOURCE_DATE_EPOCH); so does this, because those are bv's functions.
//
// A write does not refresh the session's own copy of the feedback. The file
// sits in the directory the app's watch follows, so the write is picked up by
// the reload that follows it, which reports `changed` — exactly the path an
// edit by `bv --feedback-accept` from a terminal takes. Refreshing here would
// make that reload see an unchanged fingerprint and leave the app's triage
// stale.

// triageFeedbackResult is what every feedback method returns.
type triageFeedbackResult struct {
	// Feedback is the state after the operation, as --feedback-show reports
	// it.
	Feedback analysis.FeedbackJSON `json:"feedback"`
	// Message is bv's stdout for the same flag, without the final newline.
	Message string `json:"message"`
	// Path is the feedback.json the operation read and, for a write, wrote.
	Path string `json:"path"`

	// Set by accept and ignore only.
	IssueID string   `json:"issue_id,omitempty"`
	Action  string   `json:"action,omitempty"`
	Score   *float64 `json:"score,omitempty"`
}

// loadSessionFeedback is bv's LoadFeedback over the directory this session
// reads feedback from (feedbackDir): the defaults when there is no file, and
// an error — not the defaults, as the read path uses — when the file cannot
// be parsed, so a write never silently replaces a file it could not read.
func (s *Session) loadSessionFeedback() (*analysis.FeedbackData, string, error) {
	s.mu.RLock()
	source, kind := s.source, s.kind
	s.mu.RUnlock()
	dir := feedbackDir(source, kind)
	if dir == "" {
		return nil, "", fmt.Errorf("session has no source")
	}
	fb, err := analysis.LoadFeedback(dir)
	if err != nil {
		return nil, "", fmt.Errorf("Error loading feedback: %w", err)
	}
	return fb, dir, nil
}

func feedbackResult(fb *analysis.FeedbackData, dir, message string) triageFeedbackResult {
	return triageFeedbackResult{
		Feedback: fb.ToJSON(),
		Message:  message,
		Path:     filepath.Join(dir, analysis.FeedbackFile),
	}
}

// triageFeedbackShow is --feedback-show. It writes nothing.
func (s *Session) triageFeedbackShow() ([]byte, error) {
	fb, dir, err := s.loadSessionFeedback()
	if err != nil {
		return nil, err
	}
	// bv prints the block with json.MarshalIndent, two spaces.
	text, err := json.MarshalIndent(fb.ToJSON(), "", "  ")
	if err != nil {
		return nil, err
	}
	return json.Marshal(feedbackResult(fb, dir, string(text)))
}

// triageFeedbackReset is --feedback-reset: every verdict dropped and every
// adjustment back to 1, written to the file — which stays, as bv leaves it.
func (s *Session) triageFeedbackReset() ([]byte, error) {
	s.feedbackWriteMu.Lock()
	defer s.feedbackWriteMu.Unlock()

	fb, dir, err := s.loadSessionFeedback()
	if err != nil {
		return nil, err
	}
	fb.Reset()
	if err := fb.Save(dir); err != nil {
		return nil, fmt.Errorf("Error saving feedback: %w", err)
	}
	return json.Marshal(feedbackResult(fb, dir, "Feedback data reset to defaults."))
}

// feedbackScoreClock is the instant a verdict's score is computed at: the
// wall clock, never SOURCE_DATE_EPOCH. bv 0.25.2's --feedback-accept scores a
// fresh analyzer it never pins (NewAnalyzer takes time.Now), so its score —
// whose risk factor reads a bead's age — moves with the wall clock whatever
// the environment says. Matching bv means matching where it does not pin, as
// robotNow matches where it does. A variable so a test can fix it.
var feedbackScoreClock = time.Now

// triageFeedbackRecordRequest names the bead and the verdict.
type triageFeedbackRecordRequest struct {
	ID     string `json:"id"`
	Action string `json:"action"`
}

// triageFeedbackRecord is --feedback-accept and --feedback-ignore.
//
// The verdict carries the bead's impact score and breakdown under the
// default weights, as bv computes them — whatever feedback is already on
// file, since bv scores a fresh analyzer. A bead outside the analysis set, an
// unknown id or a tombstone, is bv's "Issue not found"; a closed bead is
// found but has no impact score, so it is recorded at zero, as bv records it.
func (s *Session) triageFeedbackRecord(req []byte) ([]byte, error) {
	var r triageFeedbackRecordRequest
	if len(req) > 0 {
		if err := json.Unmarshal(req, &r); err != nil {
			return nil, err
		}
	}
	if r.ID == "" {
		return nil, fmt.Errorf("feedback requires an \"id\"")
	}
	if r.Action != "accept" && r.Action != "ignore" {
		return nil, fmt.Errorf("invalid action: %s (must be 'accept' or 'ignore')", r.Action)
	}

	issues, an, stats := s.snapshot()
	if an == nil || stats == nil {
		return nil, fmt.Errorf("session has no analyzer")
	}
	if !slices.ContainsFunc(issues, func(issue model.Issue) bool { return issue.ID == r.ID }) {
		return nil, fmt.Errorf("Issue not found: %s", r.ID)
	}

	// bv's scores include the Phase-2 metrics, which it computes
	// synchronously. Wait before taking the clock, never while holding it.
	// The session analyzer scores with the default weights: priority sets the
	// feedback weights only for its own computation, under the same lock.
	stats.WaitForPhase2()
	s.clockMu.Lock()
	an.SetNow(feedbackScoreClock())
	scores := an.ComputeImpactScoresFromStats(stats, an.Now())
	s.clockMu.Unlock()

	var score float64
	var breakdown analysis.ScoreBreakdown
	for _, candidate := range scores {
		if candidate.IssueID == r.ID {
			score, breakdown = candidate.Score, candidate.Breakdown
			break
		}
	}

	s.feedbackWriteMu.Lock()
	defer s.feedbackWriteMu.Unlock()

	fb, dir, err := s.loadSessionFeedback()
	if err != nil {
		return nil, err
	}
	if err := fb.RecordFeedback(r.ID, r.Action, score, breakdown); err != nil {
		return nil, fmt.Errorf("Error recording feedback: %w", err)
	}
	if err := fb.Save(dir); err != nil {
		return nil, fmt.Errorf("Error saving feedback: %w", err)
	}

	result := feedbackResult(fb, dir, fmt.Sprintf(
		"Recorded %s feedback for %s (score: %.3f)\n%s", r.Action, r.ID, score, fb.Summary()))
	result.IssueID, result.Action, result.Score = r.ID, r.Action, &score
	return json.Marshal(result)
}
