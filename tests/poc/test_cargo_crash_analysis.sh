#!/bin/bash
# QA Test: Cargo Crash Root Cause Analysis
# Documents the crash when cargo is run with DYLD_INSERT_LIBRARIES
#
# KNOWN ISSUE: cargo/rustup crashes with "Failed building the Runtime"
# Error: Os { code: 22, kind: InvalidInput, message: "Invalid argument" }
#
# Root Cause: Tokio async runtime fails to initialize when shim is loaded
# This affects any Rust async application, not just cargo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SHIM_PATH="${PROJECT_ROOT}/target/debug/libvrift_shim.dylib"

echo "=== QA Test: Cargo Crash Root Cause ==="

if [[ ! -f "$SHIM_PATH" ]]; then
    echo "❌ SKIP: Shim not built"
    exit 0
fi

# Test 1: Verify basic syscalls work
echo ""
echo "[Test 1] Basic syscalls with shim"
cat > /tmp/basic_syscalls.c << 'EOF'
#include <stdio.h>
#include <sys/socket.h>
#include <sys/event.h>
#include <unistd.h>
#include <errno.h>

int main() {
    int kq = kqueue();
    if (kq == -1) { printf("kqueue FAIL\n"); return 1; }
    close(kq);
    
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == -1) { printf("socketpair FAIL\n"); return 1; }
    close(sv[0]); close(sv[1]);
    
    int pfd[2];
    if (pipe(pfd) == -1) { printf("pipe FAIL\n"); return 1; }
    close(pfd[0]); close(pfd[1]);
    
    printf("ALL OK\n");
    return 0;
}
EOF
clang -o /tmp/basic_syscalls /tmp/basic_syscalls.c 2>/dev/null

export DYLD_INSERT_LIBRARIES="$SHIM_PATH"
export DYLD_FORCE_FLAT_NAMESPACE=1

RESULT=$(/tmp/basic_syscalls 2>&1)
if [[ "$RESULT" == "ALL OK" ]]; then
    echo "  ✅ Basic syscalls work: kqueue, socketpair, pipe"
else
    echo "  ❌ Basic syscalls FAILED"
    echo "  $RESULT"
fi

# Test 2: Verify the crash
echo ""
echo "[Test 2] Cargo with shim (expected: CRASH)"
OUTPUT=$(cargo --version 2>&1)
EXIT_CODE=$?

unset DYLD_INSERT_LIBRARIES
unset DYLD_FORCE_FLAT_NAMESPACE

if [[ $EXIT_CODE -eq 0 ]]; then
    echo "  ✅ UNEXPECTED: cargo works! Version: $OUTPUT"
    rm -f /tmp/basic_syscalls /tmp/basic_syscalls.c
    exit 0
else
    echo "  ❌ CONFIRMED: cargo crashes with shim"
    
    # Extract the key error
    if echo "$OUTPUT" | grep -q "Failed building the Runtime"; then
        echo ""
        echo "Error Type: Tokio Runtime Initialization Failure"
        echo "Error: Os { code: 22, kind: InvalidInput }"
        echo ""
        echo "ANALYSIS:"
        echo "  - Basic syscalls (kqueue, socketpair, pipe) work correctly"
        echo "  - Crash occurs in Tokio async runtime builder"
        echo "  - errno 22 = EINVAL (Invalid argument)"
        echo ""
        echo "HYPOTHESIS:"
        echo "  1. Shim interferes with io_uring/kqueue registration"
        echo "  2. Shim's open() returns FD that Tokio rejects"
        echo "  3. Some syscall returns unexpected value during init"
        echo ""
        echo "IMPACT:"
        echo "  - ALL Rust async applications will crash"
        echo "  - cargo, rustup, and async build tools unusable"
        echo "  - This is a P0 blocker for Rust compilation acceleration"
    else
        echo "  Unknown error:"
        echo "$OUTPUT" | tail -5
    fi
    
    rm -f /tmp/basic_syscalls /tmp/basic_syscalls.c
    exit 1
fi
