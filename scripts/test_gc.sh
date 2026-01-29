#!/bin/bash
set -e

# Setup
TEST_DIR="/tmp/velo-gc-test"
CAS_ROOT="$TEST_DIR/cas"
MANIFEST_DIR="$TEST_DIR/manifests"
DATA_DIR="$TEST_DIR/data"
VELO_BIN="./target/debug/velo"

echo "=== Velo GC Test ==="
rm -rf "$TEST_DIR"
mkdir -p "$CAS_ROOT" "$MANIFEST_DIR" "$DATA_DIR"

# 1. Create Valid Data
echo "Creating valid data..."
echo "valid_content" > "$DATA_DIR/file.txt"
# Ingest
"$VELO_BIN" --cas-root "$CAS_ROOT" ingest "$DATA_DIR" --output "$MANIFEST_DIR/valid.manifest" > /dev/null

echo "Created manifest at $MANIFEST_DIR/valid.manifest"

# 2. Create Garbage Data
echo "Creating garbage data..."
# Manually store a blob without adding it to any manifest
GARBAGE_CONTENT="garbage_content_$(date)"
# We can use the CLI to store it, but we don't have a raw 'store' command exposed easily in main help (it's implicit in ingest).
# Hack: Ingest a different dir to a TEMPORARY manifest, then DELETE the manifest.
GARBAGE_DIR="$TEST_DIR/garbage_data"
mkdir -p "$GARBAGE_DIR"
echo "$GARBAGE_CONTENT" > "$GARBAGE_DIR/garbage.txt"
"$VELO_BIN" --cas-root "$CAS_ROOT" ingest "$GARBAGE_DIR" --output "$TEST_DIR/temp.manifest" > /dev/null
rm "$TEST_DIR/temp.manifest"
echo "Created garbage blob (manifest deleted)"

# 3. Test Dry Run
echo -e "\n--- Test 1: Dry Run (Default) ---"
"$VELO_BIN" --cas-root "$CAS_ROOT" gc --manifests "$MANIFEST_DIR"

# 4. Test Delete
echo -e "\n--- Test 2: Delete ---"
"$VELO_BIN" --cas-root "$CAS_ROOT" gc --manifests "$MANIFEST_DIR" --delete --verbose

# 5. Verify
echo -e "\n--- Verification ---"
# Check if garbage is gone
# We need to know the garbage hash. The verbose output above showed it.
# Simple check: run GC again, should report 0 garbage.
"$VELO_BIN" --cas-root "$CAS_ROOT" gc --manifests "$MANIFEST_DIR"

echo "=== Test Complete ==="
