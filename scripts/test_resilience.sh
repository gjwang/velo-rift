#!/bin/bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM_BIN="$PROJECT_ROOT/target/debug/libvrift_shim.dylib"
TEST_DIR="$PROJECT_ROOT/test_resilience_work"

mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Cleanup
pkill vriftd || true

echo "--- Resilience Test: Log Levels ---"

# 1. Test Log Level: Error (Info logs should be suppressed)
echo "Testing VRIFT_LOG_LEVEL=error..."
export VRIFT_LOG_LEVEL=error
export VRIFT_DEBUG=1
export DYLD_INSERT_LIBRARIES="$SHIM_BIN"
export DYLD_FORCE_FLAT_NAMESPACE=1
export VRIFT_VFS_PREFIX="/vfs"
export VRIFT_MANIFEST="$TEST_DIR/nonexistent.lmdb"

# This should trigger some INFO logs during init, but they should be suppressed if level check works
./simple_open /vfs/test.txt 2> logs_error.txt || true

if grep -q "\[INFO\]" logs_error.txt; then
    echo "❌ Fail: INFO logs found when level set to error"
else
    echo "✅ Success: INFO logs suppressed"
fi

# 2. Test Log Level: Trace (Should show everything)
echo "Testing VRIFT_LOG_LEVEL=trace..."
export VRIFT_LOG_LEVEL=trace
./simple_open /vfs/test.txt 2> logs_trace.txt || true

if grep -q "\[TRACE\]" logs_trace.txt; then
    echo "✅ Success: TRACE logs visible"
else
    echo "❌ Fail: TRACE logs missing"
fi

echo ""
echo "--- Resilience Test: Circuit Breaker ---"

# 3. Test Circuit Breaker: threshold=2
echo "Testing Circuit Breaker (threshold=2)..."
export VRIFT_LOG_LEVEL=info
export VRIFT_CIRCUIT_BREAKER_THRESHOLD=2
export VRIFT_DEBUG=1

# Run 5 iterations in ONE process
./simple_open /vfs/test_loop.txt 5 2> logs_cb.txt || true

if grep -q "CIRCUIT BREAKER TRIPPED" logs_cb.txt; then
    echo "✅ Success: Circuit breaker tripped message found in log"
else
    echo "❌ Fail: Circuit breaker trip message NOT found"
    cat logs_cb.txt
fi

# Count connect failures
FAIL_COUNT=$(grep -c "DAEMON CONNECTION FAILED" logs_cb.txt)
if [ "$FAIL_COUNT" -eq 2 ]; then
    echo "✅ Success: Only 2 connect attempts before trip (Target=2)"
else
    echo "❌ Fail: Found $FAIL_COUNT connect attempts, expected 2"
    cat logs_cb.txt
fi

echo "--- Resilience Test Complete ---"
# rm -rf "$TEST_DIR" # Keep for inspection
