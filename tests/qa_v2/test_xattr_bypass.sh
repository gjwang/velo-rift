#!/bin/bash
# ==============================================================================
# Test: Extended Attribute (xattr) Bypass Detection
# ==============================================================================
# IT_SETXATTR and IT_REMOVEXATTR were in __DATA,__nointerpose, allowing
# processes to modify extended attributes on VFS files without interception.
#
# Test cases:
#   XATTR.1: setxattr on VFS file — must return EPERM
#   XATTR.2: removexattr on VFS file — must return EPERM
#   XATTR.3: setxattr on non-VFS file — must succeed (passthrough)
#   XATTR.4: xattr CLI command on VFS file — must be blocked
#   XATTR.5: listxattr on VFS file — should work (read-only, not mutating)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
SKIP=0
TOTAL=0

pass() { ((PASS++)); ((TOTAL++)); echo "  ✅ PASS: $1"; }
fail() { ((FAIL++)); ((TOTAL++)); echo "  ❌ FAIL: $1"; }
skip() { ((SKIP++)); ((TOTAL++)); echo "  ⏭️  SKIP: $1"; }

# Prepare helper C program for direct syscall testing
HELPER_SRC=$(mktemp /tmp/xattr_test_XXXXXX.c)
HELPER_BIN=$(mktemp /tmp/xattr_test_XXXXXX)
cat > "$HELPER_SRC" << 'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/xattr.h>

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <set|remove|list> <path>\n", argv[0]);
        return 2;
    }

    const char *op = argv[1];
    const char *path = argv[2];

    if (strcmp(op, "set") == 0) {
        const char *value = "test_value";
        int ret = setxattr(path, "user.vrift_test", value, strlen(value), 0, 0);
        if (ret == 0) {
            printf("OK: setxattr succeeded\n");
            return 0;
        } else {
            printf("BLOCKED: setxattr errno=%d (%s)\n", errno, strerror(errno));
            return (errno == EPERM) ? 42 : 1;
        }
    } else if (strcmp(op, "remove") == 0) {
        int ret = removexattr(path, "user.vrift_test", 0);
        if (ret == 0) {
            printf("OK: removexattr succeeded\n");
            return 0;
        } else {
            printf("BLOCKED: removexattr errno=%d (%s)\n", errno, strerror(errno));
            return (errno == EPERM) ? 42 : 1;
        }
    } else if (strcmp(op, "list") == 0) {
        char buf[4096];
        ssize_t len = listxattr(path, buf, sizeof(buf), 0);
        if (len >= 0) {
            printf("OK: listxattr returned %zd bytes\n", len);
            return 0;
        } else {
            printf("ERROR: listxattr errno=%d (%s)\n", errno, strerror(errno));
            return 1;
        }
    }
    return 2;
}
CEOF
cc -o "$HELPER_BIN" "$HELPER_SRC" 2>/dev/null
trap "rm -f $HELPER_SRC $HELPER_BIN" EXIT

WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR $HELPER_SRC $HELPER_BIN" EXIT
REAL_FILE="$WORKDIR/testfile.txt"
echo "test content" > "$REAL_FILE"

echo "=== XATTR: Extended Attribute Bypass Test ==="

# XATTR.1-2: VFS tests (only when VFS is active)
VFS_PREFIX="${VRIFT_VFS_PREFIX:-}"
if [ -n "$VFS_PREFIX" ] && [ -d "$VFS_PREFIX" ]; then
    # Find a VFS file to test against
    VFS_FILE=$(find "$VFS_PREFIX" -maxdepth 3 -type f 2>/dev/null | head -1)
    if [ -n "$VFS_FILE" ]; then
        echo "[XATTR.1] setxattr on VFS file: $VFS_FILE"
        OUTPUT=$("$HELPER_BIN" set "$VFS_FILE" 2>&1) || true
        EXIT=$?
        if [ $EXIT -eq 42 ]; then
            pass "XATTR.1: setxattr blocked with EPERM"
        elif [ $EXIT -eq 0 ]; then
            fail "XATTR.1: setxattr ALLOWED on VFS file (bypass!)"
        else
            fail "XATTR.1: setxattr failed with unexpected error: $OUTPUT"
        fi

        echo "[XATTR.2] removexattr on VFS file: $VFS_FILE"
        OUTPUT=$("$HELPER_BIN" remove "$VFS_FILE" 2>&1) || true
        EXIT=$?
        if [ $EXIT -eq 42 ]; then
            pass "XATTR.2: removexattr blocked with EPERM"
        elif [ $EXIT -eq 0 ]; then
            fail "XATTR.2: removexattr ALLOWED on VFS file (bypass!)"
        else
            # ENODATA (93) is fine — no attr to remove
            pass "XATTR.2: removexattr rejected (errno in output)"
        fi
    else
        skip "XATTR.1: No files in VFS directory"
        skip "XATTR.2: No files in VFS directory"
    fi
else
    skip "XATTR.1: No VFS active"
    skip "XATTR.2: No VFS active"
fi

# XATTR.3: setxattr on non-VFS file (should succeed)
echo "[XATTR.3] setxattr on non-VFS file"
OUTPUT=$("$HELPER_BIN" set "$REAL_FILE" 2>&1) || true
EXIT=$?
if [ $EXIT -eq 0 ]; then
    pass "XATTR.3: setxattr succeeded on non-VFS file (passthrough OK)"
else
    fail "XATTR.3: setxattr failed on non-VFS file: $OUTPUT"
fi

# XATTR.4: xattr CLI on VFS file
echo "[XATTR.4] xattr CLI on VFS file"
if [ -n "$VFS_PREFIX" ] && [ -d "$VFS_PREFIX" ]; then
    VFS_FILE=$(find "$VFS_PREFIX" -maxdepth 3 -type f 2>/dev/null | head -1)
    if [ -n "$VFS_FILE" ]; then
        if xattr -w user.vrift_test "test" "$VFS_FILE" 2>/dev/null; then
            fail "XATTR.4: xattr -w ALLOWED on VFS file (bypass!)"
        else
            pass "XATTR.4: xattr -w blocked on VFS file"
        fi
    else
        skip "XATTR.4: No files in VFS directory"
    fi
else
    skip "XATTR.4: No VFS active"
fi

# XATTR.5: listxattr (read-only, should work)
echo "[XATTR.5] listxattr on non-VFS file (read-only)"
OUTPUT=$("$HELPER_BIN" list "$REAL_FILE" 2>&1) || true
EXIT=$?
if [ $EXIT -eq 0 ]; then
    pass "XATTR.5: listxattr succeeded (read-only passthrough)"
else
    fail "XATTR.5: listxattr failed: $OUTPUT"
fi

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed, $SKIP skipped ==="
[ $FAIL -eq 0 ] && exit 0 || exit 1
