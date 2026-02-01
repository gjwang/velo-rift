#!/bin/bash
# test_mkdir_recursive.sh - Verify mkdir -p and rmdir
# Priority: P2 (Build systems create nested dirs)
set -e

echo "=== Test: Mkdir Recursive and Rmdir ==="

TEST_DIR="/tmp/mkdir_test"

cleanup() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT
cleanup

echo "[1] Testing mkdir -p (recursive)..."
if mkdir -p "$TEST_DIR/a/b/c/d/e"; then
    if [ -d "$TEST_DIR/a/b/c/d/e" ]; then
        echo "    ✓ mkdir -p created nested directories"
    else
        echo "    ✗ Directories not created"
        exit 1
    fi
fi

echo "[2] Testing mkdir on existing dir..."
if mkdir "$TEST_DIR/a/b" 2>/dev/null; then
    echo "    ✗ mkdir should fail on existing dir"
    exit 1
else
    echo "    ✓ mkdir fails on existing directory"
fi

echo "[3] Testing rmdir on empty directory..."
mkdir -p "$TEST_DIR/empty"
if rmdir "$TEST_DIR/empty"; then
    if [ ! -d "$TEST_DIR/empty" ]; then
        echo "    ✓ rmdir removed empty directory"
    else
        echo "    ✗ Directory still exists"
        exit 1
    fi
fi

echo "[4] Testing rmdir on non-empty directory..."
mkdir -p "$TEST_DIR/nonempty"
echo "file" > "$TEST_DIR/nonempty/file.txt"
if rmdir "$TEST_DIR/nonempty" 2>/dev/null; then
    echo "    ✗ rmdir should fail on non-empty dir"
    exit 1
else
    echo "    ✓ rmdir fails on non-empty directory"
fi

echo ""
echo "✅ PASS: Directory operations work correctly"
exit 0
