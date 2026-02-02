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

# Avoid SIP and Signature issues by compiling a tiny chmod
cat <<EOF > "$TEST_DIR/tiny_chmod.c"
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char** argv) {
    if (argc < 3) return 1;
    int mode = (int)strtol(argv[1], NULL, 8);
    if (chmod(argv[2], mode) < 0) {
        perror("chmod");
        return 1;
    }
    return 0;
}
EOF
mkdir -p "$TEST_DIR/bin"
gcc "$TEST_DIR/tiny_chmod.c" -o "$TEST_DIR/bin/chmod"
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
