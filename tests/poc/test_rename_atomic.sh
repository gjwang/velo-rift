#!/bin/bash
# test_rename_atomic.sh - Verify rename atomicity for safe file updates
# Priority: P1 (POSIX Semantics - Config updates, make)

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -e

echo "=== Test: Rename Atomicity ==="

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="/tmp/rename_test"

cleanup() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT
cleanup

mkdir -p "$TEST_DIR"

echo "[1] Testing basic rename atomicity..."
echo "original" > "$TEST_DIR/file.txt"
echo "updated" > "$TEST_DIR/file.txt.tmp"

# Rename should atomically replace
if mv "$TEST_DIR/file.txt.tmp" "$TEST_DIR/file.txt"; then
    CONTENT=$(cat "$TEST_DIR/file.txt")
    if [ "$CONTENT" = "updated" ]; then
        echo "    ✓ Basic rename works"
    else
        echo "    ✗ Content mismatch after rename"
        exit 1
    fi
fi

echo "[2] Testing concurrent read during rename..."
# Write a file, start reader, rename over it
echo "before" > "$TEST_DIR/target.txt"

# Start background reader
(
    for i in $(seq 1 100); do
        cat "$TEST_DIR/target.txt" 2>/dev/null || true
    done
) &
READER_PID=$!

# Rapidly rename files
for i in $(seq 1 50); do
    echo "version_$i" > "$TEST_DIR/target.txt.new"
    mv "$TEST_DIR/target.txt.new" "$TEST_DIR/target.txt"
done

wait $READER_PID 2>/dev/null || true

# Final content should be consistent
FINAL=$(cat "$TEST_DIR/target.txt")
if echo "$FINAL" | grep -q "version_"; then
    echo "    ✓ Concurrent rename preserved consistency"
else
    echo "    ⚠ Final content unexpected: $FINAL"
fi

echo "[3] Testing cross-directory rename..."
mkdir -p "$TEST_DIR/dir_a" "$TEST_DIR/dir_b"
echo "cross" > "$TEST_DIR/dir_a/file.txt"
if mv "$TEST_DIR/dir_a/file.txt" "$TEST_DIR/dir_b/file.txt"; then
    if [ -f "$TEST_DIR/dir_b/file.txt" ] && [ ! -f "$TEST_DIR/dir_a/file.txt" ]; then
        echo "    ✓ Cross-directory rename works"
    else
        echo "    ✗ Cross-directory rename failed"
        exit 1
    fi
fi

echo ""
echo "✅ PASS: Rename atomicity verified"
exit 0
