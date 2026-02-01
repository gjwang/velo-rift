#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_DIR=$(mktemp -d)
VELO_PROJECT_ROOT="$TEST_DIR/workspace"
DAEMON_BIN="${PROJECT_ROOT}/target/debug/vriftd"

echo "=== P0 Gap Test: Permission Bypass (CAS Mode Corruption) ==="

# Prepare VFS
mkdir -p "$VELO_PROJECT_ROOT/.vrift"
echo "IMMUTABLE_DATA" > "$VELO_PROJECT_ROOT/protected.txt"
chmod 444 "$VELO_PROJECT_ROOT/protected.txt" # Make it read-only

# Start Daemon
rm -f /tmp/vrift.sock
(
    unset DYLD_INSERT_LIBRARIES
    unset LD_PRELOAD
    $DAEMON_BIN start > "$TEST_DIR/daemon.log" 2>&1 &
    echo $! > "$TEST_DIR/daemon.pid"
)
DAEMON_PID=$(cat "$TEST_DIR/daemon.pid")
sleep 2

# Setup Shim
export LD_PRELOAD="${PROJECT_ROOT}/target/debug/libvrift_shim.dylib"
if [[ "$(uname)" == "Darwin" ]]; then
    export DYLD_INSERT_LIBRARIES="$LD_PRELOAD"
    export DYLD_FORCE_FLAT_NAMESPACE=1
fi
export VRIFT_socket_path="/tmp/vrift.sock"

echo "Attempting chmod +w on virtual path..."
(cd "$VELO_PROJECT_ROOT" && chmod 644 protected.txt)

# Verify
CURRENT_MODE=$(stat -f "%Lp" "$VELO_PROJECT_ROOT/protected.txt")
echo "Current Mode: $CURRENT_MODE"

kill $DAEMON_PID || true
rm -rf "$TEST_DIR"

if [[ "$CURRENT_MODE" == "644" ]]; then
    echo "❌ FAIL: Permission Bypass. chmod succeeded via OS on virtual path."
    echo "   Risk: User can flip write bit on shared CAS blocks."
    exit 1
else
    echo "✅ PASS: chmod blocked or virtualized (mode unchanged)."
    exit 0
fi
