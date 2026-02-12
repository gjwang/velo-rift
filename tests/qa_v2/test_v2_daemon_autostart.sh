#!/bin/bash
set -e

# ==============================================================================
# Test: Daemon Auto-start via CLI
# ==============================================================================
# Verifies that `vrift daemon status` auto-starts the daemon if none running.
# Uses isolated socket path to avoid interference with other tests.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_setup.sh"

check_prerequisites || exit 1

log_section "Daemon Auto-start Test"

# Use the per-test isolated workspace socket (from test_setup.sh)
DAEMON_PID=""
cleanup_autostart() {
    [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true
    rm -f "$VRIFT_SOCKET_PATH"
}
trap cleanup_autostart EXIT

echo "--- Phase 2: Daemon Auto-start Test ---"

# 1. Ensure no daemon on OUR socket
echo "[1/4] Cleaning up environment..."
rm -f "$VRIFT_SOCKET_PATH"

# 2. Run CLI command that triggers auto-start
echo "[2/4] Running 'vrift daemon status'..."
VRIFT_LOG=info VRIFT_SOCKET_PATH="$VRIFT_SOCKET_PATH" \
    "$VRIFT_CLI" daemon status > "${TEST_WORKSPACE}/autostart.log" 2>&1
cat "${TEST_WORKSPACE}/autostart.log"

# 3. Verify auto-start triggered
if grep -q "Daemon not running. Attempting to start..." "${TEST_WORKSPACE}/autostart.log"; then
    echo "✅ CLI detected daemon was missing and attempted start."
else
    echo "❌ CLI failed to detect missing daemon or log message changed."
    exit 1
fi

# 4. Verify daemon is actually running
sleep 1
if [ -S "$VRIFT_SOCKET_PATH" ]; then
    echo "✅ $VRIFT_SOCKET_PATH exists."
else
    echo "❌ $VRIFT_SOCKET_PATH NOT found."
    exit 1
fi

# 4. Verify daemon reported Operational in the status output
if grep -q "running\|Operational" "${TEST_WORKSPACE}/autostart.log"; then
    echo "✅ vriftd reported Operational status."
else
    echo "❌ vriftd did NOT report Operational status."
    exit 1
fi

echo "--- Test PASSED ---"
rm -f "${TEST_WORKSPACE}/autostart.log"
