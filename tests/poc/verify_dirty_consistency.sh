#!/bin/bash
# Test: Dirty Consistency Verification (COW Triggered)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_DIR=$(mktemp -d)
export TEST_DIR
VELO_PROJECT_ROOT="$TEST_DIR/workspace"

echo "=== Test: Dirty Consistency (COW Metadata) ==="

# 1. Prepare Fake CAS and Manifest
mkdir -p "$TEST_DIR/cas/blake3/aa/bb"
CONTENT="original content"
HASH="aabb000000000000000000000000000000000000000000000000000000000000"
echo "$CONTENT" > "$TEST_DIR/cas/blake3/aa/bb/${HASH}_16.bin"

mkdir -p "$VELO_PROJECT_ROOT/.vrift"
# Manifest entry for test_file.txt
cat > "$VELO_PROJECT_ROOT/.vrift/manifest.json" << EOF
{
  "files": {
    "/test_file.txt": {
      "content_hash": [170, 187, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      "size": 16,
      "mtime": $(date +%s),
      "mode": 33188,
      "flags": 0
    }
  }
}
EOF

# Compile test program
cat > "$TEST_DIR/consistency_test.c" << 'EOF'
#include <stdio.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

void print_stat(const char* label, const char* path) {
    struct stat sb;
    if (stat(path, &sb) != 0) {
        perror("stat");
        return;
    }
    printf("[%s] path='%s' size=%lld dev=0x%llx\n", label, path, (long long)sb.st_size, (unsigned long long)sb.st_dev);
}

int main(int argc, char *argv[]) {
    if (argc < 2) return 2;
    const char* path = argv[1];

    // 1. Initial stat (should be RIFT manifest)
    print_stat("Initial", path);

    // 2. Open for write (should trigger COW)
    printf("[Open] Opening for O_RDWR...\n");
    int fd = open(path, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }

    // 3. Write data
    const char* data = "New data that is definitely longer than sixteen bytes";
    printf("[Write] Writing %lu bytes...\n", (unsigned long)strlen(data));
    if (write(fd, data, strlen(data)) < 0) { perror("write"); close(fd); return 1; }
    
    // 4. Stat while open (should be live from temp file, dev=0x52494654)
    print_stat("While Open", path);

    // 5. Close
    close(fd);
    printf("[Close] FD closed\n");

    // 6. Stat immediately after close (should still be live from staging, as dirty is delayed)
    print_stat("Post Close", path);

    return 0;
}
EOF
gcc -o "$TEST_DIR/consistency_test" "$TEST_DIR/consistency_test.c"

# Setup Shim and run test
export VRIFT_MANIFEST="$VELO_PROJECT_ROOT/.vrift/manifest.json"
export VRIFT_CAS_ROOT="$TEST_DIR/cas"

DYLD_INSERT_LIBRARIES="${PROJECT_ROOT}/target/debug/libvrift_shim.dylib" \
DYLD_FORCE_FLAT_NAMESPACE=1 \
VRIFT_SOCKET_PATH="/tmp/vrift_dummy.sock" \
VRIFT_VFS_PREFIX="$VELO_PROJECT_ROOT" \
VRIFT_DEBUG=1 \
"$TEST_DIR/consistency_test" "$VELO_PROJECT_ROOT/test_file.txt"

RET=$?
rm -rf "$TEST_DIR"
exit $RET
