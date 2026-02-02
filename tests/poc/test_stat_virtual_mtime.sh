#!/bin/bash
# Test: stat Virtual Metadata - Runtime Verification
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_DIR=$(mktemp -d)
export TEST_DIR
VELO_PROJECT_ROOT="$TEST_DIR/workspace"

echo "=== Test: stat Virtual Metadata (Runtime) ==="

# Compile test program (can't use system stat due to SIP)
cat > "$TEST_DIR/stat_test.c" << 'EOF'
#include <stdio.h>
#include <sys/stat.h>
int main(int argc, char *argv[]) {
    if (argc < 2) return 2;
    struct stat sb;
    if (stat(argv[1], &sb) != 0) { perror("stat"); return 1; }
    printf("dev=0x%llx size=%lld\n", (unsigned long long)sb.st_dev, (long long)sb.st_size);
    // RIFT device ID = 0x52494654
    if (sb.st_dev == 0x52494654) {
        printf("✅ PASS: VFS device ID detected (RIFT)\n");
        return 0;
    } else {
        printf("❌ FAIL: Not VFS device (expected 0x52494654)\n");
        return 1;
    }
}
EOF
gcc -o "$TEST_DIR/stat_test" "$TEST_DIR/stat_test.c"

# Prepare VFS workspace
mkdir -p "$VELO_PROJECT_ROOT/.vrift"
echo "test content for stat verification" > "$VELO_PROJECT_ROOT/test_file.txt"

# Setup Shim and run test
DYLD_INSERT_LIBRARIES="${PROJECT_ROOT}/target/debug/libvrift_shim.dylib" \
DYLD_FORCE_FLAT_NAMESPACE=1 \
VRIFT_SOCKET_PATH="/tmp/vrift.sock" \
VRIFT_VFS_PREFIX="$VELO_PROJECT_ROOT" \
"$TEST_DIR/stat_test" "$VELO_PROJECT_ROOT/test_file.txt"
RET=$?

rm -rf "$TEST_DIR"
exit $RET
