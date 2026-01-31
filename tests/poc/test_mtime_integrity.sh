#!/bin/bash

# This script verifies if Velo Rift preserves the 'mtime' (modified time)
# of files during the ingestion process.

echo "--- Timestamp Integrity (mtime) Verification ---"

TEST_DIR=$(mktemp -d)
CAS_ROOT="$TEST_DIR/cas"
MANIFEST="$TEST_DIR/manifest.bin"
mkdir -p "$CAS_ROOT" "$TEST_DIR/src"

# 1. Create a file with a specific past timestamp
echo "Source Content" > "$TEST_DIR/src/old_file.txt"
# Set mtime to 2020-01-01 12:00:00
touch -t 202001011200 "$TEST_DIR/src/old_file.txt"

SRC_MTIME=$(stat -f %m "$TEST_DIR/src/old_file.txt" 2>/dev/null || stat -c %Y "$TEST_DIR/src/old_file.txt")
echo "[+] Source mtime: $SRC_MTIME"

# 2. Ingest
echo "[+] Ingesting..."
./target/debug/vrift --the-source-root "$CAS_ROOT" ingest "$TEST_DIR/src" --mode solid --output "$MANIFEST" --prefix /

# 3. Verify CAS Blob mtime (If Tier-1/Tier-2 Solid, it should ideally match)
# Note: CAS assets might have their own lifecycle, but the Manifest MUST store the original mtime.
echo "[+] Checking CAS blob mtime..."
BLOB_PATH=$(find "$CAS_ROOT" -name "*.bin" | head -n 1)
if [[ -n "$BLOB_PATH" ]]; then
    BLOB_MTIME=$(stat -f %m "$BLOB_PATH" 2>/dev/null || stat -c %Y "$BLOB_PATH")
    echo "[+] CAS Blob mtime: $BLOB_MTIME"
    if [ "$SRC_MTIME" -eq "$BLOB_MTIME" ]; then
        echo "[SUCCESS] CAS Blob mtime matches source."
    else
        echo "[WARNING] CAS Blob mtime does NOT match source. This might break hardlink-based build tools."
    fi
fi

# 4. Verify Manifest Data
echo "[+] Checking Manifest metadata..."
# We use 'vrift status' but it doesn't show mtime per file yet. 
# We'll use strings or a custom tool if needed, but for now we look at the CLI code which says it stores it.

# 5. Verify Virtual Projection via Shim
echo "[+] Verifying projection via Shim..."
export VRIFT_MANIFEST="$MANIFEST"
export VR_THE_SOURCE="$CAS_ROOT"
export VRIFT_VFS_PREFIX="$TEST_DIR/projected"
export DYLD_FORCE_FLAT_NAMESPACE=1
export DYLD_INSERT_LIBRARIES="$(pwd)/target/debug/libvelo_shim.dylib"

# Check mtime of the projected path
# Currently the shim DOES NOT intercept stat, so this will fail if the file doesn't exist on disk.
if ls -l "$TEST_DIR/projected/old_file.txt" > /dev/null 2>&1; then
    PROJ_MTIME=$(stat -f %m "$TEST_DIR/projected/old_file.txt" 2>/dev/null || stat -c %Y "$TEST_DIR/projected/old_file.txt")
    echo "[+] Projected mtime: $PROJ_MTIME"
else
    echo "[FAIL] Projected file not visible to 'stat' (Shim lacks stat interception)."
fi

unset DYLD_INSERT_LIBRARIES
rm -rf "$TEST_DIR"
