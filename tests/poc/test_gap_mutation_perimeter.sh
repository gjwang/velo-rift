#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_DIR=$(mktemp -d)
VELO_PROJECT_ROOT="$TEST_DIR/workspace"
DAEMON_BIN="${PROJECT_ROOT}/target/debug/vriftd"

echo "=== P0 Gap Test: Mutation Perimeter (macOS) ==="

# Prepare VFS
mkdir -p "$VELO_PROJECT_ROOT/.vrift"
echo "PROTECTED_CONTENT_1234567890" > "$VELO_PROJECT_ROOT/mutation_test.txt"
# Make it read-only for baseline
chmod 444 "$VELO_PROJECT_ROOT/mutation_test.txt"

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
export VRIFT_VFS_PREFIX="$VELO_PROJECT_ROOT"

RESULTS=""

echo "Test 1: chained chmod + truncate()"
# Chained exploit: first chmod to bypass OS read-only check, then truncate.
# Since Shim is bypassed, both hit the host OS.
if (cd "$VELO_PROJECT_ROOT" && chmod 644 mutation_test.txt && truncate -s 0 mutation_test.txt) 2>/dev/null; then
    SIZE=$(stat -f %z "$VELO_PROJECT_ROOT/mutation_test.txt")
    if [[ "$SIZE" == "0" ]]; then
        echo "❌ FAIL: Chained mutation bypass detected (File destroyed)"
        RESULTS="$RESULTS\ntruncate_chained: FAIL"
    else
        echo "✅ PASS: Mutation blocked"
        RESULTS="$RESULTS\ntruncate_chained: PASS"
    fi
else
    echo "✅ PASS: Mutation returned error"
    RESULTS="$RESULTS\ntruncate_chained: PASS"
fi

echo "Test 2: xattr"
if (cd "$VELO_PROJECT_ROOT" && xattr -w user.test value mutation_test.txt) 2>/dev/null; then
    VAL=$(xattr -p user.test "$VELO_PROJECT_ROOT/mutation_test.txt" 2>/dev/null || echo "")
    if [[ "$VAL" == "value" ]]; then
        echo "❌ FAIL: xattr bypass detected (Metadata modified)"
        RESULTS="$RESULTS\nxattr: FAIL"
    else
         echo "✅ PASS: xattr blocked or virtualized"
         RESULTS="$RESULTS\nxattr: PASS"
    fi
else
    echo "✅ PASS: xattr returned error"
    RESULTS="$RESULTS\nxattr: PASS"
fi

echo "Test 3: chflags (macOS only)"
if [[ "$(uname)" == "Darwin" ]]; then
    if (cd "$VELO_PROJECT_ROOT" && chflags uchg mutation_test.txt) 2>/dev/null; then
        FLAGS=$(stat -f %f "$VELO_PROJECT_ROOT/mutation_test.txt")
        if [[ "$FLAGS" != "0" ]]; then
            echo "❌ FAIL: chflags bypass detected (Flags modified)"
            RESULTS="$RESULTS\nchflags: FAIL"
            # Cleanup flags so we can delete temp dir
            chflags nouchg "$VELO_PROJECT_ROOT/mutation_test.txt"
        else
            echo "✅ PASS: chflags blocked or virtualized"
            RESULTS="$RESULTS\nchflags: PASS"
        fi
    else
        echo "✅ PASS: chflags returned error"
        RESULTS="$RESULTS\nchflags: PASS"
    fi
fi

kill $DAEMON_PID || true
rm -rf "$TEST_DIR"

echo -e "\n=== Summary ===$RESULTS"
