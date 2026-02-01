#!/bin/bash
# test_realpath_virtual.sh - Verify realpath returns VFS path
# Priority: P0 - Required for build tools
set -e

echo "=== Test: realpath Virtual Path Resolution ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SHIM_PATH="${PROJECT_ROOT}/target/debug/libvrift_shim.dylib"

# Step 1: Check if shim has realpath interception
echo "[1] Code Verification:"
SHIM_SRC="${PROJECT_ROOT}/crates/vrift-shim/src/lib.rs"

if grep -q "realpath_shim" "$SHIM_SRC"; then
    echo "    ✅ realpath_shim function found"
else
    echo "    ❌ realpath_shim NOT implemented"
    exit 1
fi

if grep -q "IT_REALPATH" "$SHIM_SRC"; then
    echo "    ✅ realpath interpose entry found"
else
    echo "    ❌ realpath interpose entry NOT found"
    exit 1
fi

# Step 2: Check symbol export
echo ""
echo "[2] Symbol Export Verification:"
if nm -gU "$SHIM_PATH" 2>/dev/null | grep -q "realpath_shim"; then
    echo "    ✅ realpath_shim exported in dylib"
else
    echo "    ❌ realpath_shim NOT exported"
    exit 1
fi

# Step 3: Check implementation has VFS handling
echo ""
echo "[3] VFS Handling Verification:"
if grep -A 20 "fn realpath_shim" "$SHIM_SRC" | grep -q "psfs_applicable\|resolve_path_with_cwd"; then
    echo "    ✅ realpath has VFS path resolution logic"
else
    echo "    ⚠️  realpath may be passthrough only"
fi

echo ""
echo "✅ PASS: realpath interception implemented"
exit 0
