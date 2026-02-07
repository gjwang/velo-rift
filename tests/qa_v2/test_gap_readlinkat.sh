#!/bin/bash
# ==============================================================================
# Gap Test: readlinkat interposition
# ==============================================================================
# Verifies that readlink and readlinkat return VFS-synthetic symlink targets
# for VFS-managed symlinks. The shim currently interposes readlink but NOT
# readlinkat — this is a known gap.
#
# Expected: readlinkat returns the VFS symlink target (not underlying FS).
# ==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/test_setup.sh"

check_prerequisites || exit 1

log_section "Gap: readlinkat Interposition"

start_daemon || exit 1

# Create workspace structure
mkdir -p "$TEST_WORKSPACE/src/subdir"

# We need a symlink that exists in VFS.
# Create content via shim first, then test readlink/readlinkat
echo "target content" > "$TEST_WORKSPACE/src/real_target.txt"

# Create symlink via shim
run_with_shim ln -sf "real_target.txt" "$TEST_WORKSPACE/src/test_link"

# Compile readlinkat probe
PROBE_SRC="$TEST_WORKSPACE/readlinkat_probe.c"
PROBE_BIN="$TEST_WORKSPACE/readlinkat_probe"

cat > "$PROBE_SRC" << 'PROBE_EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <symlink_path>\n", argv[0]);
        return 99;
    }
    const char *path = argv[1];
    char buf[4096];
    ssize_t n;

    // Test 1: readlink (path-based — interposed on macOS)
    errno = 0;
    n = readlink(path, buf, sizeof(buf) - 1);
    if (n >= 0) {
        buf[n] = '\0';
        printf("readlink: OK target='%s'\n", buf);
    } else {
        printf("readlink: FAIL errno=%d (%s)\n", errno, strerror(errno));
    }

    // Test 2: readlinkat with AT_FDCWD
    errno = 0;
    n = readlinkat(AT_FDCWD, path, buf, sizeof(buf) - 1);
    if (n >= 0) {
        buf[n] = '\0';
        printf("readlinkat_cwd: OK target='%s'\n", buf);
    } else {
        printf("readlinkat_cwd: FAIL errno=%d (%s)\n", errno, strerror(errno));
    }

    // Test 3: readlinkat with dirfd + basename
    const char *base = strrchr(path, '/');
    if (base) {
        char dir[2048];
        size_t dlen = (size_t)(base - path);
        memcpy(dir, path, dlen);
        dir[dlen] = '\0';
        base++;

        int dfd = open(dir, O_RDONLY | O_DIRECTORY);
        if (dfd >= 0) {
            errno = 0;
            n = readlinkat(dfd, base, buf, sizeof(buf) - 1);
            if (n >= 0) {
                buf[n] = '\0';
                printf("readlinkat_dfd: OK target='%s'\n", buf);
            } else {
                printf("readlinkat_dfd: FAIL errno=%d (%s)\n", errno, strerror(errno));
            }
            close(dfd);
        } else {
            printf("readlinkat_dfd: SKIP (cannot open dir)\n");
        }
    }

    return 0;
}
PROBE_EOF

cc -o "$PROBE_BIN" "$PROBE_SRC" -Wall 2>/dev/null || {
    log_fail "Failed to compile readlinkat probe"
    exit_with_summary
}

# Run probe under shim
OUTPUT=$(run_with_shim "$PROBE_BIN" "$TEST_WORKSPACE/src/test_link" 2>&1)
echo "$OUTPUT"

# ============================================================================
# Evaluate results
# ============================================================================

log_test "G-READLINK.1" "readlink() on VFS symlink returns target"
if echo "$OUTPUT" | grep "^readlink:" | grep -q "OK"; then
    log_pass "readlink() returns symlink target"
else
    log_fail "readlink() failed on VFS symlink"
fi

log_test "G-READLINK.2" "readlinkat(AT_FDCWD) on VFS symlink returns target"
if echo "$OUTPUT" | grep "^readlinkat_cwd:" | grep -q "OK"; then
    log_pass "readlinkat(AT_FDCWD) returns symlink target"
else
    ERRNO=$(echo "$OUTPUT" | grep "^readlinkat_cwd:" | sed 's/.*errno=\([0-9]*\).*/\1/')
    log_fail "readlinkat(AT_FDCWD) failed (errno=$ERRNO) — GAP: readlinkat not interposed"
fi

log_test "G-READLINK.3" "readlinkat(dirfd) on VFS symlink returns target"
if echo "$OUTPUT" | grep "^readlinkat_dfd:" | grep -q "OK"; then
    log_pass "readlinkat(dirfd) returns symlink target"
else
    ERRNO=$(echo "$OUTPUT" | grep "^readlinkat_dfd:" | sed 's/.*errno=\([0-9]*\).*/\1/')
    log_fail "readlinkat(dirfd) failed (errno=$ERRNO) — GAP: readlinkat not interposed"
fi

exit_with_summary
