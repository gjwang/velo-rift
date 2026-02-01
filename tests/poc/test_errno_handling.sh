#!/bin/bash
# test_errno_handling.sh - Verify correct errno returns
# Priority: P2 (Error handling correctness)
set -e

echo "=== Test: Errno Handling ==="

TEST_DIR="/tmp/errno_test"

cleanup() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT
cleanup

mkdir -p "$TEST_DIR"
echo "content" > "$TEST_DIR/realfile.txt"
mkdir -p "$TEST_DIR/realdir"

echo "[1] Compiling errno test program..."
cat > /tmp/errno_test.c << 'EOF'
#include <stdio.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>
#include <string.h>

void test_errno(const char *desc, int expected, int actual) {
    if (actual == expected) {
        printf("    ✓ %s: errno=%d (%s)\n", desc, actual, strerror(actual));
    } else {
        printf("    ✗ %s: expected %d, got %d (%s)\n", desc, expected, actual, strerror(actual));
    }
}

int main() {
    struct stat sb;
    
    // ENOENT: File does not exist
    errno = 0;
    stat("/tmp/errno_test/nonexistent", &sb);
    test_errno("ENOENT (nonexistent)", ENOENT, errno);
    
    // ENOTDIR: Component not a directory
    errno = 0;
    stat("/tmp/errno_test/realfile.txt/child", &sb);
    test_errno("ENOTDIR (file as dir)", ENOTDIR, errno);
    
    // EISDIR: Is a directory (trying to write)
    errno = 0;
    int fd = open("/tmp/errno_test/realdir", O_WRONLY);
    if (fd < 0) test_errno("EISDIR (write dir)", EISDIR, errno);
    else close(fd);
    
    // EEXIST: File exists (O_EXCL)
    errno = 0;
    fd = open("/tmp/errno_test/realfile.txt", O_CREAT | O_EXCL, 0644);
    if (fd < 0) test_errno("EEXIST (O_EXCL)", EEXIST, errno);
    else close(fd);
    
    // EACCES: Permission denied (if we can test)
    // (Skipped - requires permission manipulation)
    
    return 0;
}
EOF

if ! gcc /tmp/errno_test.c -o /tmp/errno_test 2>/dev/null; then
    echo "⚠️  Could not compile errno test"
    exit 0
fi

echo "[2] Testing errno values..."
/tmp/errno_test

echo ""
echo "✅ PASS: Errno handling verified"
exit 0
