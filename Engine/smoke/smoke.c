// Smoke test for the vbx engine C ABI. Not shipped; built by Scripts/build-engine.sh --check.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libvbxgo.h"

static int fail = 0;

static void expect(const char *what, int cond) {
    printf("%-28s %s\n", what, cond ? "ok" : "FAIL");
    if (!cond) fail = 1;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: smoke <workspace-path>\n");
        return 2;
    }

    char config[4096];
    snprintf(config, sizeof(config), "{\"path\":\"%s\"}", argv[1]);

    char *res = vbx_open(config);
    printf("open  -> %.120s\n", res);
    expect("open reports ok", strstr(res, "\"ok\":true") != NULL);

    // Handle is the integer after "handle":
    long handle = 0;
    const char *h = strstr(res, "\"handle\":");
    if (h) handle = strtol(h + 9, NULL, 10);
    expect("handle is non-zero", handle != 0);
    vbx_free(res);

    res = vbx_call(handle, "info", NULL);
    printf("info  -> %.200s\n", res);
    expect("info ok", strstr(res, "\"ok\":true") != NULL);
    vbx_free(res);

    res = vbx_call(handle, "metrics", NULL);
    expect("metrics ok", strstr(res, "\"ok\":true") != NULL);
    expect("metrics has node_count", strstr(res, "node_count") != NULL);
    vbx_free(res);

    res = vbx_call(handle, "wait_phase2", NULL);
    expect("phase2 ready", strstr(res, "\"phase2_ready\":true") != NULL);
    expect("pagerank present", strstr(res, "pagerank") != NULL);
    vbx_free(res);

    res = vbx_call(handle, "plan", NULL);
    expect("plan ok", strstr(res, "\"ok\":true") != NULL);
    vbx_free(res);

    // Error paths must be envelopes, not crashes.
    res = vbx_call(handle, "bogus_method", NULL);
    printf("bogus -> %.120s\n", res);
    expect("unknown method errors", strstr(res, "\"ok\":false") != NULL);
    vbx_free(res);

    res = vbx_call(999999, "info", NULL);
    expect("bad handle errors", strstr(res, "\"ok\":false") != NULL);
    vbx_free(res);

    res = vbx_call(handle, "unblocks", NULL);
    expect("missing arg errors", strstr(res, "\"ok\":false") != NULL);
    vbx_free(res);

    vbx_close(handle);

    res = vbx_call(handle, "info", NULL);
    expect("closed handle errors", strstr(res, "\"ok\":false") != NULL);
    vbx_free(res);

    printf("\n%s\n", fail ? "SMOKE FAILED" : "SMOKE PASSED");
    return fail;
}
