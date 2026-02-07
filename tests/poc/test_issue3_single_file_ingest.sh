#!/bin/bash
# Test: Issue #3 - Single File Ingest Silent Failure
# Expected: FAIL (vrift ingest exits with code 1, no output, no manifest)
# Fixed: SUCCESS (vrift ingest creates manifest or prints clear error)

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "=== Test: Single File Ingest Silent Failure ==="
echo "Issue: 'vrift ingest <file>' silently fails instead of ingesting or showing error."
echo ""

export VR_THE_SOURCE="/tmp/test_issue3_cas"
MANIFEST="/tmp/test_issue3.manifest"
TEST_FILE="/tmp/test_issue3_file.txt"

# Setup - clear immutable flags on CAS blobs from previous runs
chflags -R nouchg "$VR_THE_SOURCE" 2>/dev/null || true
rm -rf "$VR_THE_SOURCE" "$MANIFEST" "$TEST_FILE"
mkdir -p "$VR_THE_SOURCE"
echo "test content" > "$TEST_FILE"

# Prefer release builds (CI), fallback to debug
if [ -f "${PROJECT_ROOT}/target/release/vrift" ]; then
    VELO_BIN="${PROJECT_ROOT}/target/release/vrift"
else
    VELO_BIN="${PROJECT_ROOT}/target/debug/vrift"
fi

# Run ingest on a single file
echo "[RUN] $VELO_BIN --the-source-root $VR_THE_SOURCE ingest $TEST_FILE --output $MANIFEST --prefix /"
OUTPUT=$("$VELO_BIN" --the-source-root "$VR_THE_SOURCE" ingest "$TEST_FILE" --output "$MANIFEST" --prefix / 2>&1) || true

# Check results
if [ -d "$MANIFEST" ] || [ -f "$MANIFEST" ]; then
    echo "[PASS] Manifest was created."
    ls -l "$MANIFEST"
    EXIT_CODE=0
elif [ -n "$OUTPUT" ]; then
    echo "[ACCEPTABLE] No manifest, but error message provided:"
    echo "$OUTPUT"
    EXIT_CODE=0
else
    echo "[FAIL] Silent failure: No manifest created and no error message."
    EXIT_CODE=1
fi

# Cleanup
chflags -R nouchg "$VR_THE_SOURCE" 2>/dev/null || true
rm -rf "$VR_THE_SOURCE" "$MANIFEST" "$TEST_FILE"
exit $EXIT_CODE
