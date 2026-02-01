#!/bin/bash
# Shell-First Test Suite: All mutation operations MUST be intercepted
# This exposes the macOS SIP limitation that breaks DYLD_INSERT_LIBRARIES

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_DIR=$(mktemp -d)
VELO_PROJECT_ROOT="$TEST_DIR/workspace"

echo "=== Shell-First Test Suite: Mutation Operations ==="
echo "These tests verify that shell commands are properly intercepted"
echo "Build systems use: chmod, rm, mv, ln, touch, etc."

# Prepare VFS
mkdir -p "$VELO_PROJECT_ROOT/.vrift"
echo "PROTECTED" > "$VELO_PROJECT_ROOT/test.txt"
chmod 444 "$VELO_PROJECT_ROOT/test.txt"

# Setup shim environment
export DYLD_INSERT_LIBRARIES="${PROJECT_ROOT}/target/debug/libvrift_shim.dylib"
export DYLD_FORCE_FLAT_NAMESPACE=1
export VRIFT_VFS_PREFIX="$VELO_PROJECT_ROOT"

FAILURES=0

# Test 1: chmod
echo -e "\n[Test 1] chmod 644"
ORIGINAL=$(stat -f "%Lp" "$VELO_PROJECT_ROOT/test.txt")
chmod 644 "$VELO_PROJECT_ROOT/test.txt" 2>/dev/null
NEW=$(stat -f "%Lp" "$VELO_PROJECT_ROOT/test.txt")
if [[ "$ORIGINAL" != "$NEW" ]]; then
    echo "  ❌ FAIL: chmod bypassed (mode: $ORIGINAL -> $NEW)"
    ((FAILURES++))
else
    echo "  ✅ PASS: chmod blocked"
fi

# Test 2: rm (move to another location to test)
echo -e "\n[Test 2] rm"
echo "DELETABLE" > "$VELO_PROJECT_ROOT/delete_me.txt"
if rm "$VELO_PROJECT_ROOT/delete_me.txt" 2>/dev/null; then
    if [[ ! -f "$VELO_PROJECT_ROOT/delete_me.txt" ]]; then
        echo "  ❌ FAIL: rm bypassed (file deleted)"
        ((FAILURES++))
    else
        echo "  ✅ PASS: rm virtualized (file still exists on CAS)"
    fi
else
    echo "  ✅ PASS: rm blocked"
fi

# Test 3: mv (rename)
echo -e "\n[Test 3] mv (rename within VFS)"
echo "MOVABLE" > "$VELO_PROJECT_ROOT/move_me.txt"
if mv "$VELO_PROJECT_ROOT/move_me.txt" "$VELO_PROJECT_ROOT/moved.txt" 2>/dev/null; then
    echo "  ⚠️  mv succeeded - check if virtualized or bypassed"
else
    echo "  ✅ PASS: mv blocked"
fi

# Test 4: ln (hard link)
echo -e "\n[Test 4] ln (hard link)"
if ln "$VELO_PROJECT_ROOT/test.txt" "$TEST_DIR/hardlink.txt" 2>/dev/null; then
    echo "  ❌ FAIL: ln bypassed (hard link created to CAS)"
    ((FAILURES++))
else
    echo "  ✅ PASS: ln blocked"
fi

# Test 5: touch (mtime modification)
echo -e "\n[Test 5] touch (mtime change)"
ORIGINAL_MTIME=$(stat -f "%m" "$VELO_PROJECT_ROOT/test.txt")
sleep 1
touch "$VELO_PROJECT_ROOT/test.txt" 2>/dev/null
NEW_MTIME=$(stat -f "%m" "$VELO_PROJECT_ROOT/test.txt")
if [[ "$ORIGINAL_MTIME" != "$NEW_MTIME" ]]; then
    echo "  ❌ FAIL: touch bypassed (mtime changed)"
    ((FAILURES++))
else
    echo "  ✅ PASS: touch blocked"
fi

# Test 6: truncate
echo -e "\n[Test 6] truncate"
ORIGINAL_SIZE=$(stat -f "%z" "$VELO_PROJECT_ROOT/test.txt")
truncate -s 0 "$VELO_PROJECT_ROOT/test.txt" 2>/dev/null
NEW_SIZE=$(stat -f "%z" "$VELO_PROJECT_ROOT/test.txt")
if [[ "$NEW_SIZE" == "0" && "$ORIGINAL_SIZE" != "0" ]]; then
    echo "  ❌ FAIL: truncate bypassed (file emptied)"
    ((FAILURES++))
else
    echo "  ✅ PASS: truncate blocked"
fi

rm -rf "$TEST_DIR"

echo -e "\n=== Summary ==="
if [[ $FAILURES -gt 0 ]]; then
    echo "❌ $FAILURES test(s) FAILED - Shell commands bypass shim!"
    echo "   CAUSE: macOS SIP prevents DYLD_INSERT_LIBRARIES on /bin/* binaries"
    exit 1
else
    echo "✅ All shell commands properly intercepted"
    exit 0
fi
