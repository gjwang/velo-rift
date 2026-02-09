#!/bin/bash
# Master Core P0 Verification
# Ensures no deadlock and no ingestion bypass before running the full suite.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../" && pwd)"

echo "🚀 [CORE P0] Starting Pre-flight Verification..."

# 1. Check Initialization Hang (BUG-004 / Deadlock)
echo "--- Step 1: Initialization Integrity ---"
bash "${SCRIPT_DIR}/test_inception_init_hang.sh"
RC1=$?
if [ $RC1 -ne 0 ]; then
    echo "❌ FATAL: Initialization Deadlock detected."
    exit 1
fi

# 2. Check Ingestion Bypass (BUG-001 / Race)
echo ""
echo "--- Step 2: Interception Reliability ---"
bash "${SCRIPT_DIR}/repro_inception_init_race.sh"
RC2=$?
if [ $RC2 -ne 0 ]; then
    echo "❌ FATAL: VFS Interception Bypass detected (Init Race)."
    exit 1
fi

echo ""
echo "✅ [CORE P0] Pre-flight Success. System is stable."
exit 0
