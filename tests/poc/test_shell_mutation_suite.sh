#!/bin/bash
# Shell-First Test Suite: All mutation operations MUST be intercepted
# This tests actual shell commands (cp, mv, rm, chmod, etc.) under the shim
# Uses local binary copies to bypass macOS SIP

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_DIR=$(mktemp -d)
VELO_PROJECT_ROOT="$TEST_DIR/workspace"

echo "=== Shell-First Test Suite: Mutation Operations ==="
echo "These tests verify that shell commands are properly intercepted"
echo "Build systems use: chmod, rm, mv, ln, touch, cp, etc."

# Prepare VFS workspace
mkdir -p "$VELO_PROJECT_ROOT/.vrift"
echo "PROTECTED" > "$VELO_PROJECT_ROOT/test.txt"
chmod 444 "$VELO_PROJECT_ROOT/test.txt"

# Copy binaries to bypass SIP
mkdir -p "$TEST_DIR/bin"
for cmd in chmod rm mv ln touch cp cat; do
    if which $cmd >/dev/null 2>&1; then
        cp "$(which $cmd)" "$TEST_DIR/bin/$cmd"
    fi
done

# Setup shim environment with local PATH
export PATH="$TEST_DIR/bin:$PATH"
export DYLD_INSERT_LIBRARIES="${PROJECT_ROOT}/target/debug/libvrift_shim.dylib"
export DYLD_FORCE_FLAT_NAMESPACE=1
export VRIFT_VFS_PREFIX="$VELO_PROJECT_ROOT"

FAILURES=0

# Test 1: chmod
echo -e "\n[Test 1] chmod 644"
ORIGINAL=$(stat -f "%Lp" "$VELO_PROJECT_ROOT/test.txt")
"$TEST_DIR/bin/chmod" 644 "$VELO_PROJECT_ROOT/test.txt" 2>/dev/null
NEW=$(stat -f "%Lp" "$VELO_PROJECT_ROOT/test.txt")
if [[ "$ORIGINAL" != "$NEW" ]]; then
    echo "  ❌ FAIL: chmod bypassed (mode: $ORIGINAL -> $NEW)"
    ((FAILURES++))
else
    echo "  ✅ PASS: chmod blocked or virtualized"
fi

# Test 2: rm
echo -e "\n[Test 2] rm"
echo "DELETABLE" > "$VELO_PROJECT_ROOT/delete_me.txt"
if "$TEST_DIR/bin/rm" "$VELO_PROJECT_ROOT/delete_me.txt" 2>/dev/null; then
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
if "$TEST_DIR/bin/mv" "$VELO_PROJECT_ROOT/move_me.txt" "$VELO_PROJECT_ROOT/moved.txt" 2>/dev/null; then
    echo "  ⚠️  mv succeeded - check if virtualized or bypassed"
else
    echo "  ✅ PASS: mv blocked"
fi

# Test 4: cp (copy)
echo -e "\n[Test 4] cp (copy within VFS)"
echo "ORIGINAL" > "$VELO_PROJECT_ROOT/original.txt"
if "$TEST_DIR/bin/cp" "$VELO_PROJECT_ROOT/original.txt" "$VELO_PROJECT_ROOT/copy.txt" 2>/dev/null; then
    if [[ -f "$VELO_PROJECT_ROOT/copy.txt" ]]; then
        echo "  ✅ PASS: cp succeeded (expected for read-only source)"
    fi
else
    echo "  ⚠️  cp blocked"
fi

# Test 5: touch (mtime modification)
echo -e "\n[Test 5] touch (mtime change)"
ORIGINAL_MTIME=$(stat -f "%m" "$VELO_PROJECT_ROOT/test.txt")
sleep 1
"$TEST_DIR/bin/touch" "$VELO_PROJECT_ROOT/test.txt" 2>/dev/null
NEW_MTIME=$(stat -f "%m" "$VELO_PROJECT_ROOT/test.txt")
if [[ "$ORIGINAL_MTIME" != "$NEW_MTIME" ]]; then
    echo "  ❌ FAIL: touch bypassed (mtime changed)"
    ((FAILURES++))
else
    echo "  ✅ PASS: touch blocked or virtualized"
fi

# Cleanup
unset DYLD_INSERT_LIBRARIES
unset DYLD_FORCE_FLAT_NAMESPACE
rm -rf "$TEST_DIR"

echo -e "\n=== Summary ==="
if [[ $FAILURES -gt 0 ]]; then
    echo "❌ $FAILURES test(s) FAILED - Shell commands bypass shim!"
    exit 1
else
    echo "✅ All shell commands properly intercepted or virtualized"
    exit 0
fi
