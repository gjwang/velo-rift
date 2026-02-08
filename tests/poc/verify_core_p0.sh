#!/bin/bash
# Master Core P0 Verification
# Ensures no deadlock and no ingestion bypass before running the full suite.
# Budget: 50s per sub-test to fit within 120s regression timeout.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../" && pwd)"

# Shell-based timeout (macOS compatible)
run_with_timeout() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    (sleep "$secs" && kill -9 $pid 2>/dev/null) &
    local watchdog=$!
    wait $pid 2>/dev/null
    local rc=$?
    kill $watchdog 2>/dev/null; wait $watchdog 2>/dev/null
    return $rc
}

echo "🚀 [CORE P0] Starting Pre-flight Verification..."

# 1. Check Initialization Hang (BUG-004 / Deadlock)
echo "--- Step 1: Initialization Integrity ---"
run_with_timeout 50 bash "${SCRIPT_DIR}/test_inception_init_hang.sh" || {
    echo "❌ FATAL: Initialization Deadlock detected."
    exit 1
}

# 2. Check Ingestion Bypass (BUG-001 / Race)
echo ""
echo "--- Step 2: Interception Reliability ---"
run_with_timeout 50 bash "${SCRIPT_DIR}/repro_inception_init_race.sh" || {
    echo "❌ FATAL: VFS Interception Bypass detected (Init Race)."
    exit 1
}

echo ""
echo "✅ [CORE P0] Pre-flight Success. System is stable."
exit 0
