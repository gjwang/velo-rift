#!/bin/bash
# Test: Data Persistence After Restart
# Priority: P1

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Verifies that ingested files survive daemon restart

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "=== Test: Restart Recovery Behavior ==="

# Cleanup
killall vriftd 2>/dev/null || true
VR_THE_SOURCE="/tmp/restart_cas"
rm -rf "$VR_THE_SOURCE"
mkdir -p "$VR_THE_SOURCE"

# 1. Start daemon
(unset DYLD_INSERT_LIBRARIES && unset DYLD_FORCE_FLAT_NAMESPACE && "${PROJECT_ROOT}/target/debug/vriftd" start) > /tmp/vriftd_res.log 2>&1 &
D_PID=$!
sleep 2

# 2. Ingest some data
TEST_DATA=$(mktemp -d)
echo "persistent data" > "$TEST_DATA/persist.txt"
"${PROJECT_ROOT}/target/debug/vrift" --the-source-root "$VR_THE_SOURCE" ingest "$TEST_DATA" --prefix /test >/dev/null 2>&1

# 3. Kill and restart
kill -9 $D_PID 2>/dev/null || true
sleep 1
(unset DYLD_INSERT_LIBRARIES && unset DYLD_FORCE_FLAT_NAMESPACE && "${PROJECT_ROOT}/target/debug/vriftd" start) > /tmp/vriftd_res2.log 2>&1 &
D_PID2=$!
sleep 2

# 4. Verify CAS persistence
BLOB_COUNT=$(find "$VR_THE_SOURCE" -name "*.bin" 2>/dev/null | wc -l)
echo "Blobs found: $BLOB_COUNT"

kill $D_PID2 2>/dev/null || true
rm -rf "$TEST_DATA"

if [ "$BLOB_COUNT" -ge 1 ]; then
    echo "✅ PASS: Data survived restart (CAS verified)"
    exit 0
else
    echo "❌ FAIL: Data lost after restart"
    exit 1
fi
