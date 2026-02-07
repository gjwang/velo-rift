#!/bin/bash
# ==============================================================================
# Test: Syscall Number Audit (macOS ARM64)
# ==============================================================================
# Verifies that the hardcoded syscall numbers in macos_raw.rs match the
# official macOS SDK headers. Wrong syscall numbers mean the raw assembly
# is calling a DIFFERENT syscall — potentially causing silent data corruption.
#
# This test compiles a C program that emits the official numbers from
# <sys/syscall.h> and compares them against the values in macos_raw.rs.
# ==============================================================================

set -euo pipefail

PASS=0
FAIL=0
TOTAL=0

pass() { ((PASS++)); ((TOTAL++)); echo "  ✅ PASS: $1"; }
fail() { ((FAIL++)); ((TOTAL++)); echo "  ❌ FAIL: $1 (SDK=$2, code=$3)"; }

# Get the source file
SRC_FILE="${1:-$(dirname "$0")/../../crates/vrift-inception-layer/src/syscalls/macos_raw.rs}"
if [ ! -f "$SRC_FILE" ]; then
    echo "ERROR: macos_raw.rs not found at $SRC_FILE"
    exit 2
fi

echo "=== SYSCALL-AUDIT: macOS ARM64 Syscall Number Verification ==="
echo "Source: $SRC_FILE"

# Compile C program to get SDK truth
HELPER_SRC=$(mktemp /tmp/syscall_audit_XXXXXX.c)
HELPER_BIN=$(mktemp /tmp/syscall_audit_XXXXXX)
cat > "$HELPER_SRC" << 'CEOF'
#include <stdio.h>
#include <sys/syscall.h>
int main() {
    // Format: NAME=VALUE for easy parsing
    printf("SYS_OPEN=%d\n", SYS_open);
    printf("SYS_CLOSE=%d\n", SYS_close);
    printf("SYS_READ=%d\n", SYS_read);
    printf("SYS_WRITE=%d\n", SYS_write);
    printf("SYS_STAT64=%d\n", SYS_stat64);
    printf("SYS_LSTAT64=%d\n", SYS_lstat64);
    printf("SYS_FSTAT64=%d\n", SYS_fstat64);
    printf("SYS_ACCESS=%d\n", SYS_access);
    printf("SYS_CHMOD=%d\n", SYS_chmod);
    printf("SYS_UNLINK=%d\n", SYS_unlink);
    printf("SYS_RMDIR=%d\n", SYS_rmdir);
    printf("SYS_MKDIR=%d\n", SYS_mkdir);
    printf("SYS_RENAME=%d\n", SYS_rename);
    printf("SYS_TRUNCATE=%d\n", SYS_truncate);
    printf("SYS_FCHMOD=%d\n", SYS_fchmod);
    printf("SYS_FCHOWN=%d\n", SYS_fchown);
    printf("SYS_CHOWN=%d\n", SYS_chown);
    printf("SYS_LCHOWN=%d\n", SYS_lchown);
    printf("SYS_READLINK=%d\n", SYS_readlink);
    printf("SYS_OPENAT=%d\n", SYS_openat);
    printf("SYS_RENAMEAT=%d\n", SYS_renameat);
    printf("SYS_FCHMODAT=%d\n", SYS_fchmodat);
    printf("SYS_FCHOWNAT=%d\n", SYS_fchownat);
    printf("SYS_FSTATAT64=%d\n", SYS_fstatat64);
    printf("SYS_LINKAT=%d\n", SYS_linkat);
    printf("SYS_UNLINKAT=%d\n", SYS_unlinkat);
    printf("SYS_READLINKAT=%d\n", SYS_readlinkat);
    printf("SYS_SYMLINKAT=%d\n", SYS_symlinkat);
    printf("SYS_MKDIRAT=%d\n", SYS_mkdirat);
    printf("SYS_CHFLAGS=%d\n", SYS_chflags);
    printf("SYS_SETXATTR=%d\n", SYS_setxattr);
    printf("SYS_REMOVEXATTR=%d\n", SYS_removexattr);
    printf("SYS_UTIMES=%d\n", SYS_utimes);
    printf("SYS_GETATTRLIST=%d\n", SYS_getattrlist);
    printf("SYS_SETATTRLIST=%d\n", SYS_setattrlist);
    printf("SYS_MMAP=%d\n", SYS_mmap);
    printf("SYS_MUNMAP=%d\n", SYS_munmap);
    printf("SYS_FCNTL=%d\n", SYS_fcntl);
    printf("SYS_SETRLIMIT=%d\n", SYS_setrlimit);
    printf("SYS_SENDFILE=%d\n", SYS_sendfile);
    printf("SYS_FTRUNCATE=%d\n", SYS_ftruncate);
    printf("SYS_FCHFLAGS=%d\n", SYS_fchflags);
    printf("SYS_FUTIMES=%d\n", SYS_futimes);
    printf("SYS_FLOCK=%d\n", SYS_flock);
    printf("SYS_DUP=%d\n", SYS_dup);
    printf("SYS_DUP2=%d\n", SYS_dup2);
    printf("SYS_LSEEK=%d\n", SYS_lseek);
    printf("SYS_EXCHANGEDATA=%d\n", SYS_exchangedata);
    return 0;
}
CEOF
cc -arch arm64 -o "$HELPER_BIN" "$HELPER_SRC" 2>/dev/null
trap "rm -f $HELPER_SRC $HELPER_BIN" EXIT

# Get SDK values
SDK_OUTPUT=$("$HELPER_BIN")

# Extract values from Rust source
check_syscall() {
    local name="$1"
    local rust_const="$2"

    # Get SDK value
    local sdk_val=$(echo "$SDK_OUTPUT" | grep "^${name}=" | cut -d= -f2)
    if [ -z "$sdk_val" ]; then
        echo "  ⚠️  WARN: $name not found in SDK"
        return
    fi

    # Get code value from Rust source (look for const SYS_XXX: i64 = NNN;)
    local code_val=$(grep -E "const ${rust_const}:.*=.*;" "$SRC_FILE" | head -1 | grep -oE '[0-9]+' | tail -1)
    if [ -z "$code_val" ]; then
        echo "  ⚠️  WARN: $rust_const not found in source"
        return
    fi

    if [ "$sdk_val" = "$code_val" ]; then
        pass "$rust_const = $sdk_val"
    else
        fail "$rust_const" "$sdk_val" "$code_val"
    fi
}

echo ""
echo "--- Core syscalls ---"
check_syscall SYS_OPEN SYS_OPEN
check_syscall SYS_CLOSE SYS_CLOSE
check_syscall SYS_STAT64 SYS_STAT64
check_syscall SYS_LSTAT64 SYS_LSTAT64
check_syscall SYS_FSTAT64 SYS_FSTAT64
check_syscall SYS_ACCESS SYS_ACCESS
check_syscall SYS_READLINK SYS_READLINK
check_syscall SYS_MMAP SYS_MMAP
check_syscall SYS_MUNMAP SYS_MUNMAP
check_syscall SYS_FCNTL SYS_FCNTL

echo ""
echo "--- *at syscalls (high risk) ---"
check_syscall SYS_OPENAT SYS_OPENAT
check_syscall SYS_FSTATAT64 SYS_FSTATAT64
check_syscall SYS_RENAMEAT SYS_RENAMEAT
check_syscall SYS_FCHMODAT SYS_FCHMODAT
check_syscall SYS_FCHOWNAT SYS_FCHOWNAT
check_syscall SYS_LINKAT SYS_LINKAT
check_syscall SYS_UNLINKAT SYS_UNLINKAT
check_syscall SYS_READLINKAT SYS_READLINKAT
check_syscall SYS_SYMLINKAT SYS_SYMLINKAT
check_syscall SYS_MKDIRAT SYS_MKDIRAT

echo ""
echo "--- Mutation syscalls ---"
check_syscall SYS_CHMOD SYS_CHMOD
check_syscall SYS_FCHMOD SYS_FCHMOD
check_syscall SYS_FCHOWN SYS_FCHOWN
check_syscall SYS_CHOWN SYS_CHOWN
check_syscall SYS_LCHOWN SYS_LCHOWN
check_syscall SYS_UNLINK SYS_UNLINK
check_syscall SYS_RMDIR SYS_RMDIR
check_syscall SYS_MKDIR SYS_MKDIR
check_syscall SYS_RENAME SYS_RENAME
check_syscall SYS_TRUNCATE SYS_TRUNCATE
check_syscall SYS_CHFLAGS SYS_CHFLAGS
check_syscall SYS_SETXATTR SYS_SETXATTR
check_syscall SYS_REMOVEXATTR SYS_REMOVEXATTR
check_syscall SYS_UTIMES SYS_UTIMES
check_syscall SYS_GETATTRLIST SYS_GETATTRLIST
check_syscall SYS_SETATTRLIST SYS_SETATTRLIST

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
[ $FAIL -eq 0 ] && exit 0 || exit 1
