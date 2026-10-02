// vbx's additions to its copy of bv's correlation package (ADR-027). Files
// named vbx_* are vbx's own; scripts/vendor-correlation.py leaves them alone
// and every other file is bv's, regenerated, never edited.

package correlation

// vbxPreferSnapshotPath replaces bv's choice between its two extractions.
// bv takes `git log -p` for a beads file under 64 KB and the snapshot diff
// above that, and proves the two produce byte-identical events; the snapshot
// path needs only `git log --raw` and `git cat-file`, so vbx always takes it
// and objgit never has to render a patch.
func vbxPreferSnapshotPath(*Extractor) bool { return true }

// HistoryArtifact is everything a history report takes from git: the
// lifecycle events, each strategy's correlations and the walked window. It
// depends only on the repository's HEAD and the options, never on the bead
// set, which is why bv caches it separately — and why vbx can assemble a
// report for any scope from one extraction.
type HistoryArtifact = historyArtifact

// ExtractArtifact walks the history once — bv's extractHistoryArtifact.
// opts.CausalityBeadID is honoured, as in bv; ExtractCausalHistory gets the
// same evidence without repeating the walk.
func (c *Correlator) ExtractArtifact(opts CorrelatorOptions) (*HistoryArtifact, error) {
	return c.extractHistoryArtifact(opts)
}

// ExtractCausalHistory reads the full committed record of one bead, the part
// of an artifact only --robot-causality asks for.
func (c *Correlator) ExtractCausalHistory(target string, opts CorrelatorOptions) (*CausalHistory, error) {
	return c.extractor.extractCausalHistory(target, ExtractOptions{
		Revision: opts.Revision,
		Since:    opts.Since,
		Until:    opts.Until,
		Limit:    opts.Limit,
		BeadID:   opts.BeadID,
	})
}

// WithCausalHistory returns a copy of the artifact carrying one bead's
// causal record, leaving the original — which a cache may share — untouched.
func (a *HistoryArtifact) WithCausalHistory(history *CausalHistory) *HistoryArtifact {
	copied := *a
	copied.CausalHistory = history
	return &copied
}

// AssembleReport builds the report for a bead set from an artifact — bv's
// assembleReport, which GenerateReport runs after extracting. It reads the
// artifact without changing it, so one artifact serves every scope.
func (c *Correlator) AssembleReport(beads []BeadInfo, opts CorrelatorOptions, art *HistoryArtifact) *HistoryReport {
	return c.assembleReport(beads, opts, art)
}
