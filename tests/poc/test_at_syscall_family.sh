#!/bin/bash
# Test: AT Syscall Family Behavior
# Priority: P1

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)

echo "=== Test: AT Syscall Family Behavior ==="

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# Create test directory and file
mkdir -p "$TEST_DIR/subdir"
echo "at_test_content" > "$TEST_DIR/subdir/test.txt"

export TEST_DIR="$TEST_DIR"

# Test AT syscalls with Python
DYLD_INSERT_LIBRARIES="${PROJECT_ROOT}/target/debug/libvrift_shim.dylib" DYLD_FORCE_FLAT_NAMESPACE=1 python3 << 'EOF'
import os
import sys

test_dir = os.environ.get("TEST_DIR", "/tmp")
subdir = os.path.join(test_dir, "subdir")
test_file = "test.txt"

try:
    # 1. openat test (via os.open with dir_fd)
    dir_fd = os.open(subdir, os.O_RDONLY | os.O_DIRECTORY)
    fd = os.open(test_file, os.O_RDONLY, dir_fd=dir_fd)
    content = os.read(fd, 100)
    os.close(fd)
    
    if b"at_test_content" in content:
        print("✅ PASS: open(dir_fd=...) works correctly")
    else:
        print(f"❌ FAIL: open content mismatch: {content}")
        sys.exit(1)
        
    # 2. faccessat test (via os.access with dir_fd)
    if os.access(test_file, os.R_OK, dir_fd=dir_fd):
        print("✅ PASS: access(dir_fd=...) works correctly")
    else:
        print("❌ FAIL: access(dir_fd=...) reports no R_OK permission")
        sys.exit(1)
        
    # 3. fstatat test (via os.stat with dir_fd)
    st = os.stat(test_file, dir_fd=dir_fd)
    if st.st_size > 0:
        print(f"✅ PASS: stat(dir_fd=...) works correctly (size: {st.st_size})")
    else:
        print("❌ FAIL: stat(dir_fd=...) reported 0 size")
        sys.exit(1)
    
    os.close(dir_fd)
    sys.exit(0)
    
except Exception as e:
    print(f"AT syscall error: {e}")
    sys.exit(1)
EOF
