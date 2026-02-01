#!/bin/bash
# Test: AT Syscall Family Interception
# Goal: Verify openat/faccessat/fstatat are handled for VFS files
# Priority: P1 - Compilers and build tools (make, cmake) use AT syscalls

set -e
echo "=== Test: AT Syscall Family ==="
echo ""

SHIM_PATH="${VRIFT_SHIM_PATH:-$(dirname "$0")/../../target/debug/libvelo_shim.dylib}"

echo "[1] Checking Shim for AT Syscall Implementation:"
PASS=0
FAIL=0

check_at_syscall() {
    local syscall=$1
    if [[ -f "$SHIM_PATH" ]] && nm -gU "$SHIM_PATH" 2>/dev/null | grep -qE "_${syscall}_shim$"; then
        echo "    ✅ $syscall symbol found in shim"
        PASS=$((PASS+1))
    else
        echo "    ❌ $syscall NOT intercepted in shim"
        FAIL=$((FAIL+1))
    fi
}

check_at_syscall "openat"
check_at_syscall "faccessat"
check_at_syscall "fstatat"

echo ""
echo "[2] Impact Analysis:"
echo "    AT syscalls are directory-relative variants:"
echo "    • openat(dirfd, path, flags) - open relative to directory fd"
echo "    • faccessat(dirfd, path, mode, flags) - check access relative to dirfd"
echo "    • fstatat(dirfd, path, buf, flags) - stat relative to dirfd"
echo ""
echo "    Common usage: AT_FDCWD (-2) for current working directory"
echo "    make, cmake, ninja, and modern compilers heavily use these"
echo ""

echo "[3] Summary:"
echo "    Passed: $PASS / 3"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "❌ FAIL: $FAIL AT syscalls not intercepted"
    exit 1
else
    echo "✅ PASS: All AT syscalls intercepted"
    exit 0
fi
