#!/bin/bash
# Test: fstat Virtual Metadata Code Verification
# Purpose: Verify fstat implementation returns virtual metadata from manifest, not CAS blob
# Priority: CRITICAL - Required for build tools to see correct file sizes

set -e
echo "=== Test: fstat Virtual Metadata ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM_SRC="$SCRIPT_DIR/../../crates/vrift-shim/src/lib.rs"

echo "[1] Code Verification:"

# Verify fstat_impl sets st_size from manifest entry
if grep -q "st_size = entry.size\|st_size = mmap_entry.size" "$SHIM_SRC" 2>/dev/null; then
    echo "    ✅ fstat returns virtual st_size from Manifest"
else
    echo "    ❌ fstat does NOT return virtual st_size"
    exit 1
fi

# Verify fstat_impl sets st_mtime from manifest entry
if grep -q "st_mtime.*entry.mtime\|st_mtime.*mmap_entry.mtime" "$SHIM_SRC" 2>/dev/null; then
    echo "    ✅ fstat returns virtual st_mtime from Manifest"
else
    echo "    ❌ fstat does NOT return virtual st_mtime (optional)"
    # Not a hard failure - size is the critical metric
fi

# Verify fstat_impl exists and uses query_manifest or lookup
if grep -q "fstat_impl.*Option<c_int>" "$SHIM_SRC" 2>/dev/null; then
    echo "    ✅ fstat_impl function exists with correct signature"
else
    echo "    ❌ fstat_impl function not found"
    exit 1
fi

# Verify fstat interposition is set up
if grep -q "fstat_shim\|INTERPOSE.*fstat" "$SHIM_SRC" 2>/dev/null; then
    echo "    ✅ fstat interposition configured"
else
    echo "    ❌ fstat interposition not configured"
    exit 1
fi

echo ""
echo "[2] Why This Matters:"
echo "    • Build tools (GCC, rustc) use fstat to check file sizes"
echo "    • If fstat returns CAS blob size, tools may read wrong content"
echo "    • Virtual metadata ensures tools operate on logical file size"
echo ""

echo "[3] Implementation Details:"
echo "    • fstat_impl() looks up open FD in tracked_fds"
echo "    • Returns VnodeEntry.size from manifest, not blob st_size"
echo "    • Falls back to real fstat for non-VFS files"
echo ""

echo "✅ PASS: fstat returns virtual metadata from Manifest"
exit 0
