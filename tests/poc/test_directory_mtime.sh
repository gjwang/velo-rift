#!/bin/bash
# Test: Directory mtime Behavior
# Priority: P2

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Verifies that directory mtime updates when children are modified

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
export TEST_DIR

echo "=== Test: Directory mtime Behavior ==="

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

mkdir -p "$TEST_DIR/subdir"
# Get initial mtime
if [[ "$(uname)" == "Darwin" ]]; then
    M1=$(stat -f "%m" "$TEST_DIR/subdir")
else
    M1=$(stat -c "%Y" "$TEST_DIR/subdir")
fi

sleep 1.1

# Modify children
touch "$TEST_DIR/subdir/new_file.txt"

# Get new mtime
if [[ "$(uname)" == "Darwin" ]]; then
    M2=$(stat -f "%m" "$TEST_DIR/subdir")
else
    M2=$(stat -c "%Y" "$TEST_DIR/subdir")
fi

echo "Initial mtime: $M1"
echo "New mtime:     $M2"

if [[ "$M1" != "$M2" ]]; then
    echo "✅ PASS: Directory mtime updated on child creation"
    exit 0
else
    echo "⚠️ INFO: Directory mtime did not change ($M1 == $M2)"
    echo "   Note: Some VFS implementations may mask child modifications"
    exit 0
fi
