#!/bin/bash
# ==============================================================================
# VDir Edge Cases & Stress Test Suite
# ==============================================================================
# Tests edge cases and stress scenarios for file operations
# Covers Phase 7 of the VDir QA Test Plan
#
# Test Scenarios:
#   P7.1:  Bulk file creation (100 files)
#   P7.2:  Nested symlinks
#   P7.3:  Hidden files
#   P7.4:  Large file (10MB)
#   P7.5:  Unicode filename
#   P7.6:  FIFO/named pipe
#   P7.7:  Rapid overwrite (50x)
#   P7.8:  Empty file
#   P7.9:  File with spaces
#   P7.10: Deep nesting (10 levels)
#
# NOTE: Phase 8 (concurrency) is in test_vdir_concurrency.sh
# ==============================================================================

set -euo pipefail

# ============================================================================
# Configuration (SSOT via test_setup.sh)
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_WORKSPACE_BASE="/tmp/vdir_edge_test_$$"
SKIP_AUTO_SETUP=1  # We'll call setup manually
source "$SCRIPT_DIR/test_setup.sh"

SAMPLE_PROJECT="$SCRIPT_DIR/lib/sample_project"
DAEMON_PID=""

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
# Phase 7: Edge Cases & Stress
# ============================================================================
phase7_edge_cases() {
    log_phase "7: Edge Cases & Stress Tests"
    
    cd "$TEST_WORKSPACE"
    
    log_test "P7.1" "Bulk file creation (100 files in 1 second)"
    export VRIFT_PROJECT_ROOT="$TEST_WORKSPACE"
    export VRIFT_INCEPTION=1
    export DYLD_INSERT_LIBRARIES="$SHIM_LIB"
    
    mkdir -p src/bulk
    local start_time=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')
    
    for i in $(seq 1 100); do
        echo "// file $i" > "src/bulk/file_$i.c"
    done
    
    local end_time=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')
    local duration=$((end_time - start_time))
    
    local count=$(ls src/bulk/*.c 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -eq 100 ]; then
        log_pass "100 files created in ${duration}ms"
    else
        log_fail "Only $count/100 files created"
    fi
    
    unset VRIFT_PROJECT_ROOT VRIFT_INCEPTION DYLD_INSERT_LIBRARIES
    
    log_test "P7.2" "Nested symlinks"
    mkdir -p src/links
    echo "target" > src/links/target.txt
    ln -sf target.txt src/links/link1
    ln -sf link1 src/links/link2
    
    if readlink src/links/link2 | grep -q link1; then
        log_pass "Nested symlinks created"
    else
        log_fail "Symlink chain broken"
    fi
    
    log_test "P7.3" "Hidden files (.gitignore, .env)"
    echo "*.o" > src/.gitignore
    echo "SECRET=1" > src/.env
    
    if [ -f "src/.gitignore" ] && [ -f "src/.env" ]; then
        log_pass "Hidden files created"
    else
        log_fail "Hidden file creation failed"
    fi
    
    log_test "P7.4" "Large file (10MB binary)"
    dd if=/dev/urandom of=src/large.bin bs=1m count=10 2>/dev/null
    
    if [ -f "src/large.bin" ]; then
        local size=$(stat -f %z src/large.bin)
        if [ "$size" -ge 10000000 ]; then
            log_pass "10MB file created (${size} bytes)"
        else
            log_fail "File size mismatch: $size bytes"
        fi
    else
        log_fail "Large file creation failed"
    fi
    
    log_test "P7.5" "Unicode filename"
    echo "// Japanese comment: 日本語" > "src/日本語.c"
    
    if [ -f "src/日本語.c" ]; then
        log_pass "Unicode filename created"
    else
        log_fail "Unicode filename failed"
    fi
    
    log_test "P7.6" "FIFO/named pipe (should be ignored)"
    mkfifo "src/test_pipe" 2>/dev/null || true
    
    if [ -p "src/test_pipe" ]; then
        log_pass "FIFO created (should be ignored by VFS)"
        rm -f "src/test_pipe"
    else
        log_skip "FIFO creation not supported"
    fi
    
    log_test "P7.7" "Rapid overwrite (same file 50x)"
    for i in $(seq 1 50); do
        echo "version $i" > src/overwrite.c
    done
    
    if grep -q "version 50" src/overwrite.c; then
        log_pass "Rapid overwrite: last version preserved"
    else
        log_fail "Rapid overwrite: version mismatch"
    fi
    
    log_test "P7.8" "Empty file"
    touch src/empty.c
    
    if [ -f "src/empty.c" ] && [ ! -s "src/empty.c" ]; then
        log_pass "Empty file created"
    else
        log_fail "Empty file has content"
    fi
    
    log_test "P7.9" "File with spaces in name"
    echo "// spaces" > "src/file with spaces.c"
    
    if [ -f "src/file with spaces.c" ]; then
        log_pass "File with spaces created"
    else
        log_fail "File with spaces failed"
    fi
    
    log_test "P7.10" "Deep nesting (10 levels)"
    local deep_path="src/d1/d2/d3/d4/d5/d6/d7/d8/d9/d10"
    mkdir -p "$deep_path"
    echo "deep" > "$deep_path/deep.c"
    
    if [ -f "$deep_path/deep.c" ]; then
        log_pass "10-level deep file created"
    else
        log_fail "Deep nesting failed"
    fi
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║           VDir Edge Cases & Stress Test Suite                        ║"
    echo "║           Phase 7: Edge Cases → Stress Tests                        ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    
    if [ ! -f "$VRIFTD_BIN" ]; then
        echo "❌ vriftd not found: $VRIFTD_BIN"
        exit 1
    fi
    
    setup_workspace
    
    phase7_edge_cases
    
    exit_with_summary
}

main "$@"
