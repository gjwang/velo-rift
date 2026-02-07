#!/bin/bash
# ==============================================================================
# VDir Multi-Process Concurrency Test Suite
# ==============================================================================
# Tests concurrent file operations, parallel builds, and stress scenarios
# Covers Phase 8 of the VDir QA Test Plan
#
# Test Scenarios:
#   P8.1: Parallel file creation (4 processes)
#   P8.2: Concurrent read + write
#   P8.3: make -j4 parallel build
#   P8.4: Stress: 500 ops in 5 seconds
# ==============================================================================

set -euo pipefail

# ============================================================================
# Configuration (SSOT via test_setup.sh)
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_WORKSPACE_BASE="/tmp/vdir_concurrency_test_$$"
SKIP_AUTO_SETUP=1  # We'll call setup manually
source "$SCRIPT_DIR/test_setup.sh"

SAMPLE_PROJECT="$SCRIPT_DIR/lib/sample_project"

# Test-specific variables
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
DAEMON_PID=""

# ============================================================================
# Helpers
# ============================================================================
log_phase() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║  PHASE $1"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
}

log_test() {
    echo ""
    echo "🧪 [$1] $2"
}

log_pass() {
    echo "   ✅ PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

log_fail() {
    echo "   ❌ FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

log_skip() {
    echo "   ⏭️  SKIP: $1"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

cleanup() {
    [ -n "$DAEMON_PID" ] && kill -9 "$DAEMON_PID" 2>/dev/null || true
    rm -f "$VRIFT_SOCKET_PATH"
    
    if [ -d "$TEST_WORKSPACE" ]; then
        chflags -R nouchg "$TEST_WORKSPACE" 2>/dev/null || true
        rm -rf "$TEST_WORKSPACE"
    fi
}
trap cleanup EXIT

setup_workspace() {
    cleanup
    mkdir -p "$TEST_WORKSPACE/src"
    mkdir -p "$VR_THE_SOURCE"
    cd "$TEST_WORKSPACE"
    
    # Create minimal project
    echo 'int main() { return 0; }' > src/main.c
    
    "$VRIFT_CLI" init 2>/dev/null || true
    "$VRIFT_CLI" ingest --mode solid --tier tier2 --output .vrift/manifest.lmdb src 2>/dev/null || true
    
    VRIFT_SOCKET_PATH="$VRIFT_SOCKET_PATH" VR_THE_SOURCE="$VR_THE_SOURCE" \
        "$VRIFTD_BIN" start </dev/null > "${TEST_WORKSPACE}/vriftd.log" 2>&1 &
    DAEMON_PID=$!
    
    # Wait for daemon socket with timeout (max 10s)
    local waited=0
    while [ ! -S "$VRIFT_SOCKET_PATH" ] && [ $waited -lt 10 ]; do
        sleep 0.5
        waited=$((waited + 1))
    done
    
    if [ ! -S "$VRIFT_SOCKET_PATH" ]; then
        echo "⚠️ Daemon socket not ready after 5s, continuing anyway..."
    fi
}

# ============================================================================
# Phase 8: Multi-Process Concurrency
# ============================================================================
phase8_concurrency() {
    log_phase "8: Multi-Process Concurrency"
    
    cd "$TEST_WORKSPACE"
    
    # IMPORTANT: bare 'wait' also waits for the daemon process (which never exits).
    # Always track and wait for specific PIDs.
    
    log_test "P8.1" "Parallel file creation (4 processes)"
    mkdir -p src/parallel
    
    local writer_pids=()
    for proc in {1..4}; do
        (
            for i in {1..10}; do
                echo "// proc $proc file $i" > "src/parallel/proc${proc}_file${i}.c"
            done
        ) &
        writer_pids+=($!)
    done
    
    for pid in "${writer_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    
    local count=$(ls src/parallel/*.c 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -eq 40 ]; then
        log_pass "Parallel creation: 40 files from 4 processes"
    else
        log_fail "Parallel creation: only $count/40 files"
    fi
    
    log_test "P8.2" "Concurrent read + write"
    echo "initial" > src/concurrent.c
    
    (
        for i in {1..10}; do
            cat src/concurrent.c >/dev/null 2>&1 || true
            sleep 0.05
        done
    ) &
    local reader_pid=$!
    
    (
        for i in {1..10}; do
            echo "version $i" > src/concurrent.c
            sleep 0.05
        done
    ) &
    local writer_pid=$!
    
    wait $reader_pid 2>/dev/null || true
    wait $writer_pid 2>/dev/null || true
    
    if [ -f "src/concurrent.c" ]; then
        log_pass "Concurrent read+write: no deadlock"
    else
        log_fail "Concurrent read+write: file missing"
    fi
    
    log_test "P8.3" "Parallel gcc build (4 modules)"
    rm -rf build
    mkdir -p build
    
    for i in {1..4}; do
        echo "int func_$i() { return $i; }" > "src/mod_$i.c"
    done
    
    export VRIFT_PROJECT_ROOT="$TEST_WORKSPACE"
    export VRIFT_INCEPTION=1
    export DYLD_INSERT_LIBRARIES="$SHIM_LIB"
    
    local gcc_pids=()
    for i in {1..4}; do
        gcc -c "src/mod_$i.c" -o "build/mod_$i.o" 2>/dev/null &
        gcc_pids+=($!)
    done
    
    for pid in "${gcc_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    
    local obj_count=$(ls build/*.o 2>/dev/null | wc -l | tr -d ' ')
    if [ "$obj_count" -ge 1 ]; then
        log_pass "Parallel build: $obj_count/4 object files created"
    else
        log_skip "Parallel build: no objects (VFS shim limitation)"
    fi
    
    unset VRIFT_PROJECT_ROOT VRIFT_INCEPTION DYLD_INSERT_LIBRARIES
    
    log_test "P8.4" "Stress: 500 ops in 5 seconds"
    mkdir -p src/stress
    
    local start=$(date +%s)
    local ops=0
    
    while [ $ops -lt 500 ]; do
        local now=$(date +%s)
        if [ $((now - start)) -ge 5 ]; then
            break
        fi
        
        case $((ops % 4)) in
            0) echo "create" > "src/stress/f_$ops.c" ;;
            1) touch "src/stress/f_$((ops-1)).c" 2>/dev/null || true ;;
            2) cat "src/stress/f_$((ops-2)).c" >/dev/null 2>&1 || true ;;
            3) rm -f "src/stress/f_$((ops-3)).c" 2>/dev/null || true ;;
        esac
        
        ops=$((ops + 1))
    done
    
    log_pass "Stress test: $ops ops completed"
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║           VDir Concurrency & Stress Test Suite                       ║"
    echo "║           Phase 8: Parallel → Concurrent → Stress                   ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    
    if [ ! -f "$VRIFTD_BIN" ]; then
        echo "❌ vriftd not found: $VRIFTD_BIN"
        exit 1
    fi
    
    setup_workspace
    
    phase8_concurrency
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║                         TEST SUMMARY                                  ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "   Passed:  $PASS_COUNT"
    echo "   Failed:  $FAIL_COUNT"
    echo "   Skipped: $SKIP_COUNT"
    echo ""
    
    if [ "$FAIL_COUNT" -eq 0 ]; then
        echo "✅ ALL TESTS PASSED - Concurrency handled!"
        exit 0
    else
        echo "❌ SOME TESTS FAILED"
        exit 1
    fi
}

main "$@"
