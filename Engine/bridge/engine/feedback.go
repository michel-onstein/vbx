package engine

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
)

// Triage feedback and the not-ready label-class: the two inputs bv 0.25's
// --robot-triage and --robot-next pass to ComputeTriageWithOptionsAndTime
// beyond the beads themselves (vbx-5ba).
//
// Feedback is `.beads/feedback.json`, written by `bv --feedback-accept` and
// `--feedback-ignore`. bv's loadRobotFeedback reads it on every scoring
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
