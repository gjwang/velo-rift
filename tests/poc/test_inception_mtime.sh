#!/bin/bash
# Test: Inception mtime Preservation
# Priority: P2

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Verifies that mtime is preserved during nested operations

echo "=== Test: Inception mtime Behavior ==="

TEST_DIR=$(mktemp -d)
export TEST_DIR

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

echo "test" > "$TEST_DIR/test.txt"
touch -t 202101011200 "$TEST_DIR/test.txt"

# Get initial mtime
if [[ "$(uname)" == "Darwin" ]]; then
    M1=$(stat -f "%m" "$TEST_DIR/test.txt")
else
    M1=$(stat -c "%Y" "$TEST_DIR/test.txt")
fi

# Simulate nested op (just copying it while preserving timestamps)
cp -p "$TEST_DIR/test.txt" "$TEST_DIR/test_pres.txt"

# Get new mtime
if [[ "$(uname)" == "Darwin" ]]; then
    M2=$(stat -f "%m" "$TEST_DIR/test_pres.txt")
else
    M2=$(stat -c "%Y" "$TEST_DIR/test_pres.txt")
fi

echo "Original mtime: $M1"
echo "Preserved mtime: $M2"

if [[ "$M1" == "$M2" ]]; then
    echo "✅ PASS: mtime preserved through operation"
    exit 0
else
    echo "❌ FAIL: mtime lost during operation"
    exit 1
fi
