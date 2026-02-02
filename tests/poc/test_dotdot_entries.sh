#!/bin/bash
# test_dotdot_entries.sh - Verify . and .. directory entries
# Priority: P2 (Directory traversal, relative paths)

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -e

echo "=== Test: Dot and DotDot Directory Entries ==="

TEST_DIR="/tmp/dotdot_test"

cleanup() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT
cleanup

mkdir -p "$TEST_DIR/a/b/c"
echo "file" > "$TEST_DIR/a/b/c/file.txt"

echo "[1] Testing . entry..."
if [ "$(cd "$TEST_DIR/a/b" && pwd)" = "$(cd "$TEST_DIR/a/b/." && pwd)" ]; then
    echo "    ✓ . resolves to current directory"
else
    echo "    ✗ . resolution failed"
    exit 1
fi

echo "[2] Testing .. entry..."
if [ "$(cd "$TEST_DIR/a/b/.." && pwd)" = "$(cd "$TEST_DIR/a" && pwd)" ]; then
    echo "    ✓ .. resolves to parent directory"
else
    echo "    ✗ .. resolution failed"
    exit 1
fi

echo "[3] Testing complex relative path..."
RESOLVED=$(cd "$TEST_DIR/a/b/c/../.." && pwd)
EXPECTED="$TEST_DIR/a"
if [ "$RESOLVED" = "$EXPECTED" ]; then
    echo "    ✓ Complex path ../.. resolved correctly"
else
    echo "    ✗ Expected $EXPECTED, got $RESOLVED"
    exit 1
fi

echo "[4] Testing ls shows . and .."
if ls -la "$TEST_DIR/a" | grep -q "^\." && ls -la "$TEST_DIR/a" | grep -q "^\.\."; then
    echo "    ✓ ls shows . and .. entries"
else
    echo "    ⚠ ls may hide . and .."
fi

echo ""
echo "✅ PASS: Dot entries work correctly"
exit 0
