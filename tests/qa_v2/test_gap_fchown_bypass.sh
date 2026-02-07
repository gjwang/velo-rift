#!/bin/bash
# ==============================================================================
# Gap Test: fchown/fchownat bypass detection
# ==============================================================================
# Verifies that the shim blocks ownership changes (fchown, fchownat, lchown,
# chown) on VFS-managed files. The shim currently interposes fchown/fchownat
# via __interpose, but chown/lchown may be missing.
#
# Expected: All ownership mutations return EPERM for VFS files.
# ==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/test_setup.sh"

check_prerequisites || exit 1

log_section "Gap: fchown/fchownat Bypass Detection"

start_daemon || exit 1

# Create a test file inside VFS workspace
TEST_FILE="$TEST_WORKSPACE/src/owned_file.txt"
echo "owned content" > "$TEST_FILE"

# Compile the fchown probe
PROBE_SRC="$TEST_WORKSPACE/fchown_probe.c"
PROBE_BIN="$TEST_WORKSPACE/fchown_probe"

cat > "$PROBE_SRC" << 'PROBE_EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <path>\n", argv[0]);
        return 99;
    }
    const char *path = argv[1];
    int fd, ret;
    uid_t uid = getuid();
    gid_t gid = getgid();

    // Test 1: chown (path-based)
    errno = 0;
    ret = chown(path, uid, gid);
    printf("chown: ret=%d errno=%d (%s)\n", ret, errno, strerror(errno));

    // Test 2: lchown (path-based, no-follow)
    errno = 0;
    ret = lchown(path, uid, gid);
    printf("lchown: ret=%d errno=%d (%s)\n", ret, errno, strerror(errno));

    // Test 3: fchown (FD-based)
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        printf("fchown: SKIP (cannot open fd)\n");
    } else {
        errno = 0;
        ret = fchown(fd, uid, gid);
        printf("fchown: ret=%d errno=%d (%s)\n", ret, errno, strerror(errno));
        close(fd);
    }

    // Test 4: fchownat (dirfd-based)
    // Use AT_FDCWD with basename
    const char *base = strrchr(path, '/');
    if (base) base++; else base = path;
    char dir[2048];
    size_t dlen = (size_t)(base - path);
    if (dlen > 0 && dlen < sizeof(dir)) {
        memcpy(dir, path, dlen);
        dir[dlen] = '\0';
        int dfd = open(dir, O_RDONLY | O_DIRECTORY);
        if (dfd >= 0) {
            errno = 0;
            ret = fchownat(dfd, base, uid, gid, 0);
            printf("fchownat: ret=%d errno=%d (%s)\n", ret, errno, strerror(errno));
            close(dfd);
        } else {
            printf("fchownat: SKIP (cannot open dir)\n");
        }
    } else {
        printf("fchownat: SKIP (path parse)\n");
    }

    return 0;
}
PROBE_EOF

cc -o "$PROBE_BIN" "$PROBE_SRC" -Wall 2>/dev/null || {
    log_fail "Failed to compile fchown probe"
    exit_with_summary
}

# Run probe under shim
OUTPUT=$(run_with_shim "$PROBE_BIN" "$TEST_FILE" 2>&1)
echo "$OUTPUT"

# ============================================================================
# Evaluate results
# ============================================================================

# Test 1: chown on VFS file should return EPERM
log_test "G-FCHOWN.1" "chown() on VFS file returns EPERM"
if echo "$OUTPUT" | grep "^chown:" | grep -q "errno=1"; then
    log_pass "chown() blocked with EPERM"
else
    ACTUAL_ERRNO=$(echo "$OUTPUT" | grep "^chown:" | sed 's/.*errno=\([0-9]*\).*/\1/')
    log_fail "chown() NOT blocked (errno=$ACTUAL_ERRNO, expected 1/EPERM) — GAP: chown not interposed"
fi

# Test 2: lchown on VFS file should return EPERM
log_test "G-FCHOWN.2" "lchown() on VFS file returns EPERM"
if echo "$OUTPUT" | grep "^lchown:" | grep -q "errno=1"; then
    log_pass "lchown() blocked with EPERM"
else
    ACTUAL_ERRNO=$(echo "$OUTPUT" | grep "^lchown:" | sed 's/.*errno=\([0-9]*\).*/\1/')
    log_fail "lchown() NOT blocked (errno=$ACTUAL_ERRNO, expected 1/EPERM) — GAP: lchown not interposed"
fi

# Test 3: fchown on VFS file should return EPERM
log_test "G-FCHOWN.3" "fchown() on VFS file returns EPERM"
if echo "$OUTPUT" | grep "^fchown:" | grep -q "errno=1"; then
    log_pass "fchown() blocked with EPERM"
else
    ACTUAL_ERRNO=$(echo "$OUTPUT" | grep "^fchown:" | sed 's/.*errno=\([0-9]*\).*/\1/')
    log_fail "fchown() NOT blocked (errno=$ACTUAL_ERRNO, expected 1/EPERM) — IT_FCHOWN active but may be broken"
fi

# Test 4: fchownat on VFS file should return EPERM
log_test "G-FCHOWN.4" "fchownat() on VFS file returns EPERM"
if echo "$OUTPUT" | grep "^fchownat:" | grep -q "errno=1"; then
    log_pass "fchownat() blocked with EPERM"
else
    ACTUAL_ERRNO=$(echo "$OUTPUT" | grep "^fchownat:" | sed 's/.*errno=\([0-9]*\).*/\1/')
    log_fail "fchownat() NOT blocked (errno=$ACTUAL_ERRNO, expected 1/EPERM) — IT_FCHOWNAT may be broken"
fi

exit_with_summary
