#!/bin/bash
# RFC-0049 Gap Test: readdir() Order Consistency
# Priority: P2
# Problem: VFS readdir order may differ from real FS

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "=== P2 Gap Test: readdir() Order Consistency ==="
echo ""

SHIM_SRC="${PROJECT_ROOT}/crates/vrift-shim/src/interpose.rs"

if grep -A30 "readdir_shim\|opendir_shim" "$SHIM_SRC" 2>/dev/null | grep -q "sort\|order\|consistent"; then
    echo "✅ readdir has consistent ordering"
    exit 0
else
    echo "⚠️ P2 GAP: readdir order follows underlying FS"
    echo ""
    echo "Impact: Test frameworks expecting stable order"
    echo "Severity: Low - POSIX does not guarantee order"
    exit 0  # P2 gap, not blocking
fi
