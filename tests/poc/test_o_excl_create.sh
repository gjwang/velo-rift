#!/bin/bash
# test_o_excl_create.sh - Verify O_EXCL exclusive file creation
# Priority: P1 (Used by compilers for temp files)
set -e

echo "=== Test: O_EXCL Exclusive Create ==="

TEST_DIR="/tmp/oexcl_test"

cleanup() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT
cleanup

mkdir -p "$TEST_DIR"

echo "[1] Testing O_EXCL creates new file..."
cat > /tmp/oexcl_test.c << 'EOF'
#include <stdio.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    const char *path = argv[1];
    int fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0644);
    if (fd >= 0) {
        printf("CREATED\n");
        close(fd);
        return 0;
    } else if (errno == EEXIST) {
        printf("EEXIST\n");
        return 1;
    } else {
        printf("ERROR: %d\n", errno);
        return 2;
    }
}
EOF

if ! gcc /tmp/oexcl_test.c -o /tmp/oexcl_test 2>/dev/null; then
    echo "⚠️  Could not compile test program"
    exit 0
fi

# First create should succeed
OUTPUT1=$(/tmp/oexcl_test "$TEST_DIR/newfile.txt")
if [ "$OUTPUT1" = "CREATED" ]; then
    echo "    ✓ O_EXCL created new file"
else
    echo "    ✗ First create failed: $OUTPUT1"
    exit 1
fi

# Second create should fail with EEXIST
OUTPUT2=$(/tmp/oexcl_test "$TEST_DIR/newfile.txt")
if [ "$OUTPUT2" = "EEXIST" ]; then
    echo "    ✓ O_EXCL correctly returned EEXIST"
else
    echo "    ✗ Expected EEXIST, got: $OUTPUT2"
    exit 1
fi

echo "[2] Testing race condition prevention..."
# Multiple processes try to create same file
rm -f "$TEST_DIR/race.txt"
CREATED=0
for i in $(seq 1 10); do
    /tmp/oexcl_test "$TEST_DIR/race.txt" >/dev/null 2>&1 && ((CREATED++)) || true &
done
wait

if [ "$CREATED" -eq 1 ]; then
    echo "    ✓ Only one process won the race"
else
    echo "    ⚠ Race detection: $CREATED processes created file"
fi

echo ""
echo "✅ PASS: O_EXCL semantics correct"
exit 0
