#!/bin/bash
# Test: getcwd/chdir work correctly under the shim
# Purpose: Verify chdir and getcwd don't infinite-recurse or break under flat namespace
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

echo "=== Test: getcwd/chdir Under Shim ==="

# Compile test program
cat > "$TEST_DIR/chdir_test.c" << 'EOF'
#include <stdio.h>
#include <unistd.h>
#include <string.h>
int main(int argc, char *argv[]) {
    if (argc < 2) return 2;
    
    // Test chdir to a real directory
    if (chdir(argv[1]) != 0) { perror("chdir"); return 1; }
    printf("chdir to %s: OK\n", argv[1]);
    
    // Test getcwd
    char cwd[1024];
    if (getcwd(cwd, sizeof(cwd)) == NULL) { perror("getcwd"); return 1; }
    printf("getcwd: %s\n", cwd);
    
    // Verify we're in a directory that contains "testdir"
    if (strstr(cwd, "testdir") != NULL) {
        printf("✅ PASS: getcwd/chdir work correctly under shim\n");
        return 0;
    } else {
        printf("❌ FAIL: getcwd returned unexpected path\n");
        return 1;
    }
}
EOF
gcc -o "$TEST_DIR/chdir_test" "$TEST_DIR/chdir_test.c"
codesign -s - -f "$TEST_DIR/chdir_test" 2>/dev/null || true

# Create a target directory for chdir
mkdir -p "$TEST_DIR/testdir/subdir"
echo "test" > "$TEST_DIR/testdir/subdir/file.txt"

# Use release shim if available
SHIM_LIB="${PROJECT_ROOT}/target/release/libvrift_inception_layer.dylib"
[ ! -f "$SHIM_LIB" ] && SHIM_LIB="${PROJECT_ROOT}/target/debug/libvrift_inception_layer.dylib"
codesign -s - -f "$SHIM_LIB" 2>/dev/null || true

# Run under shim — test that chdir/getcwd work correctly
# We use VRIFT_VFS_PREFIX=/vrift (a virtual path that won't conflict with real paths)
set +e
DYLD_INSERT_LIBRARIES="$SHIM_LIB" \
DYLD_FORCE_FLAT_NAMESPACE=1 \
VRIFT_VFS_PREFIX="/vrift" \
"$TEST_DIR/chdir_test" "$TEST_DIR/testdir"
RET=$?
set -e

exit $RET
