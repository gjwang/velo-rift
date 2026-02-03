#!/bin/bash
# ============================================================================
# Bug Reproduction: Shim Bootstrap Deadlock (Pattern 2648)
# ============================================================================
# This script reproduces the hang observed when using RwLock in the shim's 
# global state (io.rs) during process bootstrap on macOS ARM64.
#
# Finding: RwLock in Rust's stdlib triggers TLS/Pthread features that are not
# safe during dyld's interpose initialization.
#
# Required: Revert crates/vrift-shim/src/syscalls/io.rs to use RwLock.

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VRIFT_BIN="$PROJECT_ROOT/target/release/vrift"
SHIM_LIB="$PROJECT_ROOT/target/release/libvrift_shim.dylib"
MINI_READ="$PROJECT_ROOT/tests/qa_v2/mini_read"

# Setup work dir
WORK_DIR="/tmp/vrift_repro_hang"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/project/src"
echo "Repro Content" > "$WORK_DIR/project/src/hello.txt"

echo "----------------------------------------------------------------"
echo "🐞 Reproduction: Shim Bootstrap Hang (RwLock)"
echo "----------------------------------------------------------------"

# 1. Ingest
echo "⚡ Preparing VFS Project..."
export VRIFT_CAS_ROOT="$WORK_DIR/cas"
$VRIFT_BIN init "$WORK_DIR/project" >/dev/null 2>&1
$VRIFT_BIN ingest "$WORK_DIR/project" --mode solid >/dev/null 2>&1

VFS_ENV="DYLD_INSERT_LIBRARIES=$SHIM_LIB DYLD_FORCE_FLAT_NAMESPACE=1 VRIFT_MANIFEST=$WORK_DIR/project/.vrift/manifest.lmdb VRIFT_VFS_PREFIX=$WORK_DIR/project"

# 2. Trigger Hang
echo "🚀 Running test with 5s timeout (Expected to HANG if bug exists)..."

# We use 'timeout' (if available) or a background process kill
if command -v timeout &> /dev/null; then
    if timeout 5s env $VFS_ENV "$MINI_READ" "$WORK_DIR/project/src/hello.txt" > "$WORK_DIR/output.log" 2>&1; then
        echo "✅ Test Finished (No Hang detected - code might be patched)"
    else
        EXIT_CODE=$?
        if [ $EXIT_CODE -eq 124 ]; then
            echo "🔥 BUG DETECTED: Process HANGED (Timed out after 5s)"
            echo "   This confirms the RwLock deadlock in Shim bootstrap."
            exit 0 # Success for a reproduction test means finding the bug
        else
            echo "❌ Unexpected failure (Exit Code: $EXIT_CODE)"
            cat "$WORK_DIR/output.log"
            exit 1
        fi
    fi
else
    # Simple background kill if no timeout command
    env $VFS_ENV "$MINI_READ" "$WORK_DIR/project/src/hello.txt" > "$WORK_DIR/output.log" 2>&1 &
    PID=$!
    sleep 5
    if kill -0 $PID 2>/dev/null; then
        echo "🔥 BUG DETECTED: Process HANGED (Still running after 5s)"
        kill -9 $PID 2>/dev/null || true
        exit 0
    else
        echo "✅ Test Finished (No Hang detected)"
        wait $PID || true
    fi
fi

echo "⚠️  Reproduction failed: Bug not found. Ensure io.rs is using RwLock."
exit 1
