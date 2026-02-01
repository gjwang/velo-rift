#!/bin/bash
# Shell-First Test: chmod must be intercepted even when called from shell
# This is the REAL test - build systems use shell scripts, not C programs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_DIR=$(mktemp -d)
VELO_PROJECT_ROOT="$TEST_DIR/workspace"

echo "=== Shell-First Test: chmod Interception ==="
echo "This test verifies that /bin/chmod is properly intercepted"
echo "Build systems (npm, cargo, make) use shell commands, not C syscalls"

# Prepare VFS
mkdir -p "$VELO_PROJECT_ROOT/.vrift"
echo "PROTECTED_CONTENT" > "$VELO_PROJECT_ROOT/test.txt"
chmod 444 "$VELO_PROJECT_ROOT/test.txt"
ORIGINAL_MODE=$(stat -f "%Lp" "$VELO_PROJECT_ROOT/test.txt")
echo "Original mode: $ORIGINAL_MODE"

# Setup Shim - this should affect ALL child processes including /bin/chmod
export DYLD_INSERT_LIBRARIES="${PROJECT_ROOT}/target/debug/libvrift_shim.dylib"
export DYLD_FORCE_FLAT_NAMESPACE=1
export VRIFT_VFS_PREFIX="$VELO_PROJECT_ROOT"

# Test: Shell's chmod command (the REAL test)
echo "Running: chmod 644 $VELO_PROJECT_ROOT/test.txt"

# Capture if chmod succeeds or fails
if chmod 644 "$VELO_PROJECT_ROOT/test.txt" 2>/dev/null; then
    NEW_MODE=$(stat -f "%Lp" "$VELO_PROJECT_ROOT/test.txt")
    echo "chmod succeeded. New mode: $NEW_MODE"
    if [[ "$NEW_MODE" != "$ORIGINAL_MODE" ]]; then
        echo "❌ FAIL: Shell chmod BYPASSED shim (mode changed from $ORIGINAL_MODE to $NEW_MODE)"
        echo "   CRITICAL: /bin/chmod is not intercepted!"
        echo "   Cause: macOS SIP prevents DYLD_INSERT_LIBRARIES on system binaries"
        rm -rf "$TEST_DIR"
        exit 1
    else
        echo "✅ PASS: chmod was virtualized (mode unchanged on disk)"
        rm -rf "$TEST_DIR"
        exit 0
    fi
else
    echo "chmod returned error (blocked by shim)"
    echo "✅ PASS: Shell chmod properly blocked"
    rm -rf "$TEST_DIR"
    exit 0
fi
