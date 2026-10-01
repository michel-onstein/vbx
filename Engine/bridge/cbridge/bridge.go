// Command cbridge exposes vbx's engine through a small C ABI so a native
// macOS app can call bv's analysis code in-process.
//
// Build with:
//
//	go build -buildmode=c-archive -o libvbxgo.a ./cbridge
//
// ABI contract
//
//	vbx_open(config_json)          -> JSON envelope, caller frees with vbx_free
//	vbx_call(handle, method, req)  -> JSON envelope, caller frees with vbx_free
//	vbx_close(handle)              -> void
//	vbx_free(ptr)                  -> void
//	vbx_version()                  -> JSON envelope, caller frees with vbx_free
//	vbx_probe(path)                -> JSON envelope, caller frees with vbx_free
//
// Every entry point returns the same envelope shape, so the client has exactly
// one error path to handle:
//
//	{"ok":true,  "handle":1}          // open
//	{"ok":true,  "data":{...}}        // call
//	{"ok":false, "error":"message"}   // either
//
// Sessions are addressed by an opaque integer handle rather than a pointer
// because cgo forbids passing Go pointers into C and storing them there.
package main

/*
#include <stdlib.h>
#include <stdint.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"runtime/debug"
	"sync"
	"unsafe"

	"github.com/qjam/vbx/engine/engine"
)

func main() {}

var (
	mu       sync.RWMutex
	sessions = map[int64]*engine.Session{}
	nextID   int64
)

// envelope renders the uniform response shape. data must already be valid JSON.
func envelope(data json.RawMessage, handle int64, err error) *C.char {
	out := map[string]any{}
	if err != nil {
		out["ok"] = false
		out["error"] = err.Error()
	} else {
		out["ok"] = true
		if data != nil {
			out["data"] = data
		}
		if handle != 0 {
			out["handle"] = handle
		}
	}
	buf, merr := json.Marshal(out)
	if merr != nil {
		// Last-resort literal: the marshaller itself failed, so we cannot
		// round-trip merr through it.
		return C.CString(`{"ok":false,"error":"response marshalling failed"}`)
	}
	return C.CString(string(buf))
}

// recoverToError converts a panic inside the engine into an ordinary error.
// A panic must never cross the ABI boundary: unwinding into Swift frames is
// undefined behaviour and would take the host app down.
func recoverToError(err *error) {
	if r := recover(); r != nil {
		*err = fmt.Errorf("engine panic: %v\n%s", r, debug.Stack())
	}
}

//export vbx_open
func vbx_open(configJSON *C.char) *C.char {
	var err error
	defer recoverToError(&err)

	var cfg engine.OpenConfig
	if configJSON != nil {
		raw := C.GoString(configJSON)
		if raw != "" {
			if err = json.Unmarshal([]byte(raw), &cfg); err != nil {
				return envelope(nil, 0, fmt.Errorf("bad config: %w", err))
			}
		}
	}

	var s *engine.Session
	s, err = engine.Open(cfg)
	if err != nil {
		return envelope(nil, 0, err)
	}

	mu.Lock()
	nextID++
	id := nextID
	sessions[id] = s
	mu.Unlock()

	return envelope(nil, id, nil)
}

//export vbx_call
func vbx_call(handle C.int64_t, method *C.char, req *C.char) *C.char {
	var err error
	defer recoverToError(&err)

	mu.RLock()
	s, ok := sessions[int64(handle)]
	mu.RUnlock()
	if !ok {
		return envelope(nil, 0, fmt.Errorf("invalid handle %d", int64(handle)))
	}
	if method == nil {
		return envelope(nil, 0, fmt.Errorf("method is required"))
	}

	var reqBytes []byte
	if req != nil {
		if s := C.GoString(req); s != "" {
			reqBytes = []byte(s)
		}
	}

	var data []byte
	data, err = s.Call(C.GoString(method), reqBytes)
	if err != nil {
		return envelope(nil, 0, err)
	}
	return envelope(json.RawMessage(data), 0, nil)
}

//export vbx_close
func vbx_close(handle C.int64_t) {
	mu.Lock()
	s, ok := sessions[int64(handle)]
	delete(sessions, int64(handle))
	mu.Unlock()
	if ok {
		s.Close()
	}
}

//export vbx_free
func vbx_free(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}

//export vbx_version
func vbx_version() *C.char {
	info := map[string]string{"bridge": "1", "engine": "beads_viewer"}
	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, d := range bi.Deps {
			if d.Path == "github.com/Dicklesworthstone/beads_viewer" {
				info["engine_version"] = d.Version
			}
		}
	}
	raw, _ := json.Marshal(info)
	return envelope(json.RawMessage(raw), 0, nil)
}
