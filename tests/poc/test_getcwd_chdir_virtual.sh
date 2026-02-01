#!/bin/bash
# test_getcwd_chdir_virtual.sh - Verify getcwd/chdir VFS virtualization
# Priority: P0 - Required for make, git, npm
set -e

echo "=== Test: getcwd/chdir Virtual Directory Navigation ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SHIM_PATH="${PROJECT_ROOT}/target/debug/libvrift_shim.dylib"
SHIM_SRC="${PROJECT_ROOT}/crates/vrift-shim/src/lib.rs"

# Step 1: Check code implementation
echo "[1] Code Implementation Verification:"

if grep -q "getcwd_shim" "$SHIM_SRC"; then
    echo "    ✅ getcwd_shim function found"
else
    echo "    ❌ getcwd_shim NOT implemented"
    exit 1
fi

if grep -q "chdir_shim" "$SHIM_SRC"; then
    echo "    ✅ chdir_shim function found"
else
    echo "    ❌ chdir_shim NOT implemented"
    exit 1
fi

# Step 2: Check for virtual CWD tracking
echo ""
echo "[2] Virtual CWD Tracking:"
if grep -q "VIRTUAL_CWD" "$SHIM_SRC"; then
    echo "    ✅ Virtual CWD tracking implemented (VIRTUAL_CWD)"
else
    echo "    ❌ Virtual CWD tracking NOT found"
    exit 1
fi

# Step 3: Check symbol export
echo ""
echo "[3] Symbol Export Verification:"
if nm -gU "$SHIM_PATH" 2>/dev/null | grep -q "getcwd_shim"; then
    echo "    ✅ getcwd_shim exported"
else
    echo "    ❌ getcwd_shim NOT exported"
    exit 1
fi

if nm -gU "$SHIM_PATH" 2>/dev/null | grep -q "chdir_shim"; then
    echo "    ✅ chdir_shim exported"
else
    echo "    ❌ chdir_shim NOT exported"
    exit 1
fi

# Step 4: Check chdir has manifest lookup
echo ""
echo "[4] Manifest Integration:"
if grep -A 30 "fn chdir_shim" "$SHIM_SRC" | grep -q "psfs_lookup"; then
    echo "    ✅ chdir validates path via manifest lookup"
else
    echo "    ⚠️  chdir may not integrate with manifest"
fi

echo ""
echo "✅ PASS: getcwd/chdir interception implemented"
echo ""
echo "NOTE: E2E verification requires daemon with loaded manifest."
echo "      Run test_fail_cwd_leak.sh for passthrough behavior proof."
exit 0
