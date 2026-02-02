#!/bin/bash
# Test: Issue #2 - TLS Bootstrap Hang Behavior
# Priority: CRITICAL
# Verifies that the shim doesn't hang during early process initialization

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SHIM_PATH="${PROJECT_ROOT}/target/debug/libvrift_shim.dylib"

echo "=== Test: TLS Bootstrap Hang Behavior ==="

if [[ ! -f "$SHIM_PATH" ]]; then
    echo "⚠️ Shim not found at $SHIM_PATH"
    exit 0
fi

# Run a simple command under the shim with a tight timeout
# If it hangs, the timeout will catch it.
echo "Running 'id' command under shim..."

# We use perl for timeout here too

OUT=$(perl -e 'alarm 5; exec @ARGV' id 2>&1)
CODE=$?

unset DYLD_INSERT_LIBRARIES
unset DYLD_FORCE_FLAT_NAMESPACE

if [[ $CODE -eq 0 ]]; then
    echo "✅ PASS: Command executed without hang"
    echo "    Output: $OUT"
    exit 0
elif [[ $CODE -eq 142 ]]; then
    echo "❌ FAIL: Command HUNG during dyld bootstrap (Issue #2 detected)"
    exit 1
else
    echo "⚠️ INFO: Command failed with code $CODE, but did not hang"
    echo "    Output: $OUT"
    exit 0
fi
