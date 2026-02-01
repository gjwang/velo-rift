#!/bin/bash
# ============================================================================
# VRift Functional Test: CoW / Iron Law Protection
# ============================================================================
# Verifies that:
# 1. Solid modes create immutable hardlinks.
# 2. Direct user writes to CAS-linked files are blocked (if supported by FS).
# 3. VRift-Shim intercepts writes, unsets immutable flag, and performs CoW.
# ============================================================================

set -e

# Helper for cleaning up files that might be immutable (Solid hardlinks)
safe_rm() {
    local target="$1"
    if [ -e "$target" ]; then
        if [ "$(uname -s)" == "Darwin" ]; then
            chflags -R nouchg "$target" 2>/dev/null || true
        else
            # Try chattr -i on Linux if available
            chattr -R -i "$target" 2>/dev/null || true
        fi
        rm -rf "$target"
    fi
}

# Setup paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VELO_BIN="${PROJECT_ROOT}/target/release/vrift"

# Detect OS and set platform-specifics
OS_TYPE=$(uname -s)
if [ "$OS_TYPE" == "Darwin" ]; then
    SHIM_LIB="${PROJECT_ROOT}/target/release/libvelo_shim.dylib"
    PRELOAD_VAR="DYLD_INSERT_LIBRARIES"
    STAT_NLINK="stat -f %l"
else
    SHIM_LIB="${PROJECT_ROOT}/target/release/libvelo_shim.so"
    PRELOAD_VAR="LD_PRELOAD"
    STAT_NLINK="stat -c %h"
fi

WRITER_BIN="${PROJECT_ROOT}/target/release/examples/writer"

# Ensure binaries exist
if [ ! -f "$VELO_BIN" ] || [ ! -f "$WRITER_BIN" ] || [ ! -f "$SHIM_LIB" ]; then
    echo "Building release binaries..."
    cargo build --release --example writer -p vrift-shim
fi

TEST_DIR=$(mktemp -d)
trap 'safe_rm "$TEST_DIR" 2>/dev/null || true' EXIT

echo "Testing CoW/Iron Law in $TEST_DIR"

CAS_ROOT="$TEST_DIR/cas"
MANIFEST="$TEST_DIR/manifest.bin"
mkdir -p "$CAS_ROOT"

# 1. Create original content
# 2. Ingest (Solid Mode - Hardlink)
# 2. Ingest (Solid Mode - Hardlink)
mkdir -p "$TEST_DIR/source"
echo "Original Content" > "$TEST_DIR/source/original.txt"

PHYSICAL_ROOT="$(realpath "$TEST_DIR/source")"
# Explicitly set output to a directory for LMDB
VRIFT_MANIFEST_DIR="$TEST_DIR/manifest.lmdb"
$VELO_BIN --the-source-root "$CAS_ROOT" ingest "$PHYSICAL_ROOT" --mode solid --prefix "$PHYSICAL_ROOT" --output "$VRIFT_MANIFEST_DIR"

# 3. Verify it's a hardlink
NLINK=$($STAT_NLINK "$PHYSICAL_ROOT/original.txt")
if [ "$NLINK" -lt 2 ]; then
    echo "Error: Not a hardlink (nlink=$NLINK)!"
    exit 1
fi

CAS_FILE=$(find "$CAS_ROOT" -type f | grep -v "\.lock" | head -n 1)
echo "CAS File: $CAS_FILE"

# 4. Start vriftd (Shim now requires it)
DAEMON_BIN="${PROJECT_ROOT}/target/release/vriftd"
export VR_THE_SOURCE="$(realpath "$CAS_ROOT")"

echo "Starting daemon..."
"$DAEMON_BIN" --manifest "$VRIFT_MANIFEST_DIR" --socket /tmp/vrift.sock > "$TEST_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!
sleep 1 # Wait for daemon to start

cleanup() {
    echo "Cleaning up..."
    kill $DAEMON_PID 2>/dev/null || true
    safe_rm "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# 5. Scenario A: Direct modification (WITHOUT SHIM)
echo ""
echo "Step 1: Modifying WITHOUT shim (Should fail or be blocked)..."
# Set write bit off to test FS protection if supported
chmod -w "$PHYSICAL_ROOT/original.txt" || true
if ! echo "corrupted" > "$PHYSICAL_ROOT/original.txt" 2>/dev/null; then
    echo "✓ CAS protected! (Direct write blocked)"
else
    CORRUPT_CONTENT=$(cat "$CAS_FILE")
    if [ "$CORRUPT_CONTENT" == "corrupted" ]; then
        echo "⚠️  CAS IS CORRUPTED (Iron Law not enforced at FS level)"
    else
        echo "✓ CAS is safe."
    fi
fi

# 6. Scenario B: Modification (WITH SHIM)
echo ""
echo "Step 2: Testing WITH shim (Simulating CoW)..."
export VRIFT_VFS_PREFIX="$PHYSICAL_ROOT"
export VRIFT_DEBUG=1

# Preload the shim
export "$PRELOAD_VAR"="$(realpath "$SHIM_LIB")"
if [ "$OS_TYPE" == "Darwin" ]; then
    export DYLD_FORCE_FLAT_NAMESPACE=1
fi

TEST_PATH="$PHYSICAL_ROOT/original.txt"

# This SHOULD trigger CoW, breaking link, and allowing write without corrupting CAS
echo "Running writer with shim on $TEST_PATH..."
"$WRITER_BIN" "$TEST_PATH" "new content" > "$TEST_DIR/writer_output.log" 2>&1

# Clear preload for verification
unset "$PRELOAD_VAR"
unset DYLD_FORCE_FLAT_NAMESPACE

NEW_CAS_CONTENT=$(cat "$CAS_FILE")
if [ "$NEW_CAS_CONTENT" == "Original Content" ]; then
    echo "✅ Success: CoW protected the CAS!"
else
    echo "❌ Failure: CAS was corrupted even with shim."
    echo "Actual CAS content: $NEW_CAS_CONTENT"
    echo "--- Writer Output ---"
    cat "$TEST_DIR/writer_output.log"
    echo "--- Daemon Log ---"
    cat "$TEST_DIR/daemon.log"
    exit 1
fi

# 7. Check if re-ingested
NEW_COUNT=$(find "$CAS_ROOT" -type f | grep -v "\.lock" | wc -l)
if [ "$NEW_COUNT" -gt 1 ]; then
    echo "✅ Re-ingest detected: $NEW_COUNT blobs in CAS."
else
    echo "⚠️  Warning: Re-ingest did not result in a new blob (Expected if re-ingest logic is working)."
fi

echo ""
echo "=== Test Passed ==="
exit 0
