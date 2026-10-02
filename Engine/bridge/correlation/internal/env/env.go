// Package env stands in for bv's internal/env inside vbx's copy of bv's
// correlation package, which cannot import another module's internal
// package. Only the three variables the correlation caches read exist here.
//
// Every one answers as if the caches were switched off, whatever the process
// environment says. bv's caches persist history artifacts under the user's
// cache directory — `bv` beneath it, shared with any bv the user runs — and
// switch on whenever BV_ROBOT=1. Sharing bv's files from a second binary, or
// writing outside the sandbox container from the app, is not something to
// inherit from an environment variable; vbx keeps the extraction in memory
// per session instead (history.go). The caches are a speed-up bv proves
// byte-identical to recomputing, so leaving them off changes no output. See
// ADR-027.
package env

// Var is one environment variable as bv's caches read it.
type Var struct {
	value string
}

// Get returns the variable's value: always the value fixed here.
func (v Var) Get() string { return v.value }

// Bool reports whether the variable is set to a true value.
func (v Var) Bool() bool { return v.value == "1" }

var (
	// CacheDir is BV_CACHE_DIR: unset, and never consulted while NoCache holds.
	CacheDir = Var{}
	// NoCache is BV_NO_CACHE: set, so every correlation disk cache is off.
	NoCache = Var{value: "1"}
	// Robot is BV_ROBOT: unset, so it cannot switch the caches back on.
	Robot = Var{}
)
