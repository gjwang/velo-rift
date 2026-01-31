#!/bin/bash
# set -e

# Setup paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VELO_BIN="$SCRIPT_DIR/../target/debug/vrift"
SHIM_LIB="$SCRIPT_DIR/../target/debug/libvelo_shim.dylib" # macOS

TEST_DIR=$(mktemp -d)
echo "Testing CoW/Iron Law in $TEST_DIR"

CAS_ROOT="$TEST_DIR/cas"
MANIFEST="$TEST_DIR/manifest.bin"
mkdir -p "$CAS_ROOT"

# 1. Create original content
mkdir -p "$TEST_DIR/root/project"
echo "Original Content" > "$TEST_DIR/root/project/original.txt"
ORIG_HASH=$(shasum -a 256 "$TEST_DIR/root/project/original.txt" | awk '{print $1}')

# 2. Ingest (Solid Mode - Hardlink) with explicit prefix / for predictable mapping
$VELO_BIN --the-source-root "$CAS_ROOT" ingest "$TEST_DIR/root/project" --mode solid --output "$MANIFEST" --prefix /

# 3. Verify it's a hardlink
NLINK=$(stat -f %l "$TEST_DIR/root/project/original.txt")
if [ "$NLINK" -lt 2 ]; then
    echo "Error: Not a hardlink!"
    exit 1
fi

CAS_FILE=$(find "$CAS_ROOT" -type f | grep -v "\.lock")
echo "CAS File: $CAS_FILE"

# 4. Scenario A: Direct modification (WITHOUT SHIM)
echo "Modifying WITHOUT shim..."
if ! echo "corrupted" > "$TEST_DIR/root/project/original.txt" 2>/dev/null; then
    echo "CAS protected by immutable flag! (User process blocked)"
else
    CORRUPT_CONTENT=$(cat "$CAS_FILE")
    if [ "$CORRUPT_CONTENT" == "corrupted" ]; then
        echo "Confirmed: CAS is CORRUPTED by direct write! (Iron Law violated)"
    else
        echo "CAS is safe? Unexpected."
    fi
fi

# 6. Scenario B: Modification (WITH SHIM)
echo ""
echo "Testing WITH shim (Simulating CoW)..."
export VRIFT_MANIFEST="$(realpath "$MANIFEST")"
export VR_THE_SOURCE="$(realpath "$CAS_ROOT")"
REAL_PROJECT_ROOT="$(realpath "$TEST_DIR/root/project")"
export VRIFT_VFS_PREFIX="$REAL_PROJECT_ROOT"
export DYLD_FORCE_FLAT_NAMESPACE=1
WRITER_BIN="target/debug/examples/writer"
TEST_PATH="$REAL_PROJECT_ROOT/original.txt"
cargo build --example writer > /dev/null 2>&1

# This SHOULD trigger CoW, unsetting immutable, breaking link, and allowing write
if VRIFT_DEBUG=1 DYLD_INSERT_LIBRARIES="$(realpath "$SHIM_LIB")" "$WRITER_BIN" "$TEST_PATH" "new content" > writer_debug.log 2>&1; then
    echo "Write SUCCEEDED with shim."
else
    echo "Error: Write FAILED even with shim!"
    cat writer_debug.log
fi

DYLD_INSERT_LIBRARIES="" # Unset for verification

NEW_CAS_CONTENT=$(cat "$CAS_FILE")
if [ "$NEW_CAS_CONTENT" == "Original Content" ]; then
    echo "Success: CoW protected the CAS!"
else
    echo "Failure: CAS was corrupted even with shim."
    echo "Actual CAS content: $NEW_CAS_CONTENT"
fi

# 7. Check if re-ingested
# Re-ingest should have stored "new content" in CAS
NEW_COUNT=$(find "$CAS_ROOT" -type f | grep -v "\.lock" | wc -l)
if [ "$NEW_COUNT" -gt 1 ]; then
    echo "Re-ingest detected: $NEW_COUNT blobs in CAS."
else
    echo "Warning: Re-ingest did not happen or deduplicated."
fi

# Clean up
echo "Test artifacts preserved at $TEST_DIR"
# chflags -R nouchg "$TEST_DIR" 2>/dev/null || true
# rm -rf "$TEST_DIR"
