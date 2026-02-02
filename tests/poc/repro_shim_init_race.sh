#!/bin/bash
# repro_shim_init_race.sh
# Solidifies the bug where early VFS readiness checks cause the first call to passthrough.

set -e
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VELO_BIN="$PROJECT_ROOT/target/release/vrift"
VRIFTD_BIN="$PROJECT_ROOT/target/release/vriftd"
SHIM_LIB="$PROJECT_ROOT/target/release/libvrift_shim.dylib"

TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/source"
echo "secret content" > "$TEST_DIR/source/file.txt"

# 1. Ingest
export VRIFT_CAS_ROOT="$TEST_DIR/cas"
"$VELO_BIN" ingest "$TEST_DIR/source" --prefix /vrift > /dev/null 2>&1

# 2. Start daemon
export VRIFT_MANIFEST="$TEST_DIR/source/.vrift/manifest.lmdb"
"$VRIFTD_BIN" start > "$TEST_DIR/daemon.log" 2>&1 &
sleep 2

# 3. Reproductive Step: Try to cat the virtual file as the VERY FIRST call
# If it fails with "No such file or directory", the race condition is proven.
# (Because the system /bin/cat doesn't know about /vrift/file.txt)
echo "--- Attempting first call (should fail due to race) ---"
DYLD_INSERT_LIBRARIES="$SHIM_LIB" DYLD_FORCE_FLAT_NAMESPACE=1 VRIFT_VFS_PREFIX="/vrift" VRIFT_DEBUG=1 cat /vrift/file.txt 2>&1 || true

echo ""
echo "--- Proof Analysis ---"
if grep -q "No such file or directory" "$TEST_DIR/daemon.log" 2>/dev/null; then
    echo "Wait, if it's in the daemon log, it was intercepted."
else
    echo "Check if cat output matched 'No such file':"
fi

# Clean up
pkill vriftd || true
rm -rf "$TEST_DIR"
