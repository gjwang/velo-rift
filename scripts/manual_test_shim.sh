#!/bin/bash
# Manual high-visibility test for vrift-shim
set +e

SHIM_LIB="target/debug/libvelo_shim.dylib"
MANIFEST="/tmp/manifest.bin"
CAS_ROOT="/tmp/cas"
TEST_ROOT="/tmp/vrift_test_root_$(date +%s)"

rm -rf "$CAS_ROOT"
rm -rf "$TEST_ROOT"
mkdir -p "$CAS_ROOT"
mkdir -p "$TEST_ROOT"
echo "Original Content" > "$TEST_ROOT/original.txt"

./target/debug/vrift --the-source-root "$CAS_ROOT" ingest "$TEST_ROOT" --mode solid --output "$MANIFEST" --prefix /

NLINK=$(stat -f %l "$TEST_ROOT/original.txt")
if [ "$NLINK" -lt 2 ]; then
    echo "Error: Not a hardlink after ingest! Nlink: $NLINK"
    # exit 1
fi

export VRIFT_MANIFEST="$MANIFEST"
export VR_THE_SOURCE="$CAS_ROOT"
export VRIFT_VFS_PREFIX="$TEST_ROOT"
export DYLD_FORCE_FLAT_NAMESPACE=1
export VRIFT_DEBUG=1

echo "--- STARTING SHIMMED EXECUTION ---"
DYLD_INSERT_LIBRARIES="$(realpath "$SHIM_LIB")" ./target/debug/examples/writer "$TEST_ROOT/original.txt" "new content"
echo "--- SHIMMED EXECUTION FINISHED (Exit code: $?) ---"
