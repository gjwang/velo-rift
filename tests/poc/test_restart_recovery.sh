#!/bin/bash
# Test: Data Persistence After Restart
# Priority: P1
# Verifies that ingested files survive daemon restart.
#
# Key insight: `vrift ingest` always goes through the daemon (unified architecture).
# We must pass --the-source-root explicitly so the daemon writes blobs to our
# test CAS directory instead of the global default (~/.vrift/the_source).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# SSOT: prefer release, fallback to debug
VRIFT_CLI="${PROJECT_ROOT}/target/release/vrift"
VRIFTD_BIN="${PROJECT_ROOT}/target/release/vriftd"
[ ! -f "$VRIFT_CLI" ] && VRIFT_CLI="${PROJECT_ROOT}/target/debug/vrift"
[ ! -f "$VRIFTD_BIN" ] && VRIFTD_BIN="${PROJECT_ROOT}/target/debug/vriftd"

# Ensure vdir_d symlink for vDird subprocess model
VDIRD_BIN="${PROJECT_ROOT}/target/release/vrift-vdird"
[ -f "$VDIRD_BIN" ] && [ ! -e "$(dirname "$VRIFTD_BIN")/vdir_d" ] && \
    ln -sf "vrift-vdird" "$(dirname "$VRIFTD_BIN")/vdir_d"

echo "=== Test: Restart Recovery Behavior ==="

# Kill any leftover daemons
killall vriftd 2>/dev/null || true
sleep 1

# Isolated test environment
TEST_DIR=$(mktemp -d)
CAS_ROOT="$TEST_DIR/cas"
mkdir -p "$CAS_ROOT"
export VR_THE_SOURCE="$CAS_ROOT"
export VRIFT_SOCKET_PATH="$TEST_DIR/vrift.sock"

cleanup() {
    kill $D_PID $D_PID2 2>/dev/null || true
    sleep 0.5
    chflags -R nouchg "$TEST_DIR" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# 1. Start daemon with our isolated socket
(unset DYLD_INSERT_LIBRARIES; unset DYLD_FORCE_FLAT_NAMESPACE; \
 "$VRIFTD_BIN" start) > "$TEST_DIR/daemon1.log" 2>&1 &
D_PID=$!
sleep 2

# 2. Ingest random data (avoids dedup) with explicit CAS root
mkdir -p "$TEST_DIR/source"
dd if=/dev/urandom bs=512 count=1 of="$TEST_DIR/source/persist.dat" 2>/dev/null
"$VRIFT_CLI" --the-source-root "$CAS_ROOT" ingest "$TEST_DIR/source" --prefix /test \
    > "$TEST_DIR/ingest.log" 2>&1 || true

# 3. Kill daemon harshly (simulate crash)
kill -9 $D_PID 2>/dev/null || true
wait $D_PID 2>/dev/null || true
sleep 1

# 4. Restart daemon
(unset DYLD_INSERT_LIBRARIES; unset DYLD_FORCE_FLAT_NAMESPACE; \
 "$VRIFTD_BIN" start) > "$TEST_DIR/daemon2.log" 2>&1 &
D_PID2=$!
sleep 2

# 5. Verify CAS persistence — blobs use format: blake3/ab/cd/hash_size.bin
BLOB_COUNT=$(find "$CAS_ROOT" -name "*.bin" 2>/dev/null | wc -l | tr -d ' ')
echo "Blobs found: $BLOB_COUNT"

kill $D_PID2 2>/dev/null || true

if [ "$BLOB_COUNT" -ge 1 ]; then
    echo "✅ PASS: Data survived restart (CAS verified)"
    exit 0
else
    echo "❌ FAIL: Data lost after restart"
    echo "CAS contents:"
    find "$CAS_ROOT" -type f 2>/dev/null || echo "(empty)"
    echo "Ingest log:"
    cat "$TEST_DIR/ingest.log" 2>/dev/null || true
    echo "Daemon log:"
    cat "$TEST_DIR/daemon1.log" 2>/dev/null || true
    exit 1
fi
