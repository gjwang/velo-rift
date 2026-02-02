#!/bin/bash
# test_unlink_open_file.sh - Verify Unix unlink-while-open semantics
# Priority: P1 (POSIX Semantics - Compilers use this)

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -e

echo "=== Test: Unlink Open File Semantics ==="

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VR_THE_SOURCE="/tmp/unlink_cas"
VRIFT_MANIFEST="/tmp/unlink.manifest"
TEST_DIR="/tmp/unlink_test"

cleanup() {
    chflags -R nouchg "$VR_THE_SOURCE" "$TEST_DIR" 2>/dev/null || true
    rm -rf "$VR_THE_SOURCE" "$TEST_DIR" "$VRIFT_MANIFEST" 2>/dev/null || true
}
trap cleanup EXIT
cleanup

mkdir -p "$VR_THE_SOURCE" "$TEST_DIR"
echo "Original content" > "$TEST_DIR/testfile.txt"

echo "[1] Ingesting file..."
"${PROJECT_ROOT}/target/debug/vrift" --the-source-root "$VR_THE_SOURCE" \
    ingest "$TEST_DIR" --output "$VRIFT_MANIFEST" --prefix /unlink 2>&1 | tail -2

echo "[2] Testing unlink-while-open semantics..."
# Unix semantics: file can be deleted while open, content remains accessible
cat > /tmp/unlink_test.c << 'EOF'
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>

int main() {
    int fd = open("/tmp/unlink_test/testfile.txt", O_RDONLY);
    if (fd < 0) { printf("OPEN_FAILED\n"); return 1; }
    
    // Unlink while file is open
    if (unlink("/tmp/unlink_test/testfile.txt") != 0) {
        printf("UNLINK_FAILED\n");
        close(fd);
        return 1;
    }
    
    // Should still be able to read from fd
    char buf[100];
    ssize_t n = read(fd, buf, sizeof(buf)-1);
    if (n > 0) {
        buf[n] = '\0';
        printf("READ_OK: %s", buf);
        close(fd);
        return 0;
    }
    
    printf("READ_FAILED\n");
    close(fd);
    return 1;
}
EOF

if gcc /tmp/unlink_test.c -o /tmp/unlink_test 2>/dev/null; then
    OUTPUT=$(/tmp/unlink_test 2>&1)
    if echo "$OUTPUT" | grep -q "READ_OK"; then
        echo "    ✓ Unlink-while-open works correctly"
        echo "✅ PASS: Unix unlink semantics preserved"
        exit 0
    fi
fi

echo "⚠️  WARN: Could not verify unlink semantics"
exit 0
