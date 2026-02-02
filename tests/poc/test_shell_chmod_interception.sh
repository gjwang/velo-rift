#!/bin/bash
# Test: Shell's chmod command interception
# Goal: Verify chmod is intercepted when run from shell
# Uses local binary copy to bypass macOS SIP

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_DIR=$(mktemp -d)
VELO_PROJECT_ROOT="$TEST_DIR/workspace"

echo "=== Test: Shell chmod Interception ==="

# Prepare workspace
mkdir -p "$VELO_PROJECT_ROOT/.vrift"
echo "PROTECTED" > "$VELO_PROJECT_ROOT/test.txt"
chmod 444 "$VELO_PROJECT_ROOT/test.txt"
ORIGINAL_MODE=$(stat -f "%Lp" "$VELO_PROJECT_ROOT/test.txt")
echo "Original mode: $ORIGINAL_MODE"

# Copy chmod to bypass SIP
mkdir -p "$TEST_DIR/bin"
cp /bin/chmod "$TEST_DIR/bin/chmod"
CHMOD_CMD="$TEST_DIR/bin/chmod"

# Setup Shim
export DYLD_INSERT_LIBRARIES="${PROJECT_ROOT}/target/debug/libvrift_shim.dylib"
export DYLD_FORCE_FLAT_NAMESPACE=1
export VRIFT_VFS_PREFIX="$VELO_PROJECT_ROOT"

# Test: Run chmod
echo "Running: $CHMOD_CMD 644 $VELO_PROJECT_ROOT/test.txt"

if "$CHMOD_CMD" 644 "$VELO_PROJECT_ROOT/test.txt" 2>/dev/null; then
    NEW_MODE=$(stat -f "%Lp" "$VELO_PROJECT_ROOT/test.txt")
    echo "chmod succeeded. New mode: $NEW_MODE"
    if [[ "$NEW_MODE" != "$ORIGINAL_MODE" ]]; then
        echo "❌ FAIL: chmod changed file mode (not intercepted)"
        unset DYLD_INSERT_LIBRARIES DYLD_FORCE_FLAT_NAMESPACE
        rm -rf "$TEST_DIR"
        exit 1
    else
        echo "✅ PASS: chmod succeeded but mode unchanged (virtualized)"
    fi
else
    echo "chmod returned error (blocked by shim)"
    echo "✅ PASS: Shell chmod properly blocked"
fi

unset DYLD_INSERT_LIBRARIES DYLD_FORCE_FLAT_NAMESPACE
rm -rf "$TEST_DIR"
exit 0
