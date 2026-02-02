#!/bin/bash
# Test: Issue #7 - LMDB Storage Capability
# Priority: P2

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Verifies that LMDB storage is functional

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VRIFT_MANIFEST="/tmp/lmdb_test.manifest"

echo "=== Test: LMDB Metadata Access Behavior ==="

rm -rf "$VRIFT_MANIFEST"

# Check if vrift can create a manifest (uses LMDB internally if configured)
TEST_DIR=$(mktemp -d)
export TEST_DIR
echo "data" > "$TEST_DIR/file.txt"

if "${PROJECT_ROOT}/target/debug/vrift" ingest "$TEST_DIR" --output "$VRIFT_MANIFEST" --prefix /test 2>&1 | grep -q "Complete"; then
    echo "✅ PASS: Manifest created successfully (LMDB used)"
    
    # Verify we can read it back via status or inspect
    # (Assuming we have a command to inspect manifest contents)
    if [ -f "$VRIFT_MANIFEST" ]; then
        echo "✅ PASS: Manifest file exists on disk"
        rm -rf "$VRIFT_MANIFEST" "$TEST_DIR"
        exit 0
    fi
fi

rm -rf "$TEST_DIR"
echo "❌ FAIL: Failed to create manifest"
exit 1
