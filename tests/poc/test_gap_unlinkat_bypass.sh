#!/bin/bash
# Gap Test: unlinkat bypass via file descriptor
# Proves that unlinkat can delete files even when path-based unlink is shimmed.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# SSOT: prefer release, fallback to debug
SHIM_LIB="${PROJECT_ROOT}/target/release/libvrift_inception_layer.dylib"
[ ! -f "$SHIM_LIB" ] && SHIM_LIB="${PROJECT_ROOT}/target/debug/libvrift_inception_layer.dylib"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

touch "$WORK_DIR/protected_file"

# Inline: test_unlink_shim — path-based unlink (should be blocked by shim)
cat > "$WORK_DIR/test_unlink_shim.c" << 'EOF'
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
int main(int argc, char *argv[]) {
    if (argc < 2) return 1;
    int ret = unlink(argv[1]);
    printf("unlink result: %d (%s)\n", ret, ret == 0 ? "success" : strerror(errno));
    return ret;
}
EOF
cc -O2 -o "$WORK_DIR/test_unlink_shim" "$WORK_DIR/test_unlink_shim.c"

# Inline: test_unlinkat_gap — fd-based unlinkat (bypasses path check)
cat > "$WORK_DIR/test_unlinkat_gap.c" << 'EOF'
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
int main(int argc, char *argv[]) {
    if (argc < 2) return 1;
    int dirfd = open(".", O_RDONLY | O_DIRECTORY);
    if (dirfd < 0) { perror("open dir"); return 1; }
    int ret = unlinkat(dirfd, argv[1], 0);
    printf("unlinkat result: %d (%s)\n", ret, ret == 0 ? "success" : strerror(errno));
    close(dirfd);
    return ret;
}
EOF
cc -O2 -o "$WORK_DIR/test_unlinkat_gap" "$WORK_DIR/test_unlinkat_gap.c"

export VRIFT_VFS_PREFIX="$WORK_DIR"

echo "Using VRIFT_VFS_PREFIX=$VRIFT_VFS_PREFIX"

echo -e "\n1. Testing shimmed unlink (C program):"
DYLD_INSERT_LIBRARIES="$SHIM_LIB" \
DYLD_FORCE_FLAT_NAMESPACE=1 \
"$WORK_DIR/test_unlink_shim" "$WORK_DIR/protected_file" || true

if [ -f "$WORK_DIR/protected_file" ]; then
    echo "FILE STILL EXISTS - OK (Unlink was likely blocked)"
else
    echo "BUG: FILE DELETED BY UNLINK! (Shim not working?)"
fi

echo -e "\n2. Testing UNSHIMMED unlinkat (C program):"
if [ ! -f "$WORK_DIR/protected_file" ]; then
    touch "$WORK_DIR/protected_file"
fi

DYLD_INSERT_LIBRARIES="$SHIM_LIB" \
DYLD_FORCE_FLAT_NAMESPACE=1 \
"$WORK_DIR/test_unlinkat_gap" "$WORK_DIR/protected_file" || true

if [ -f "$WORK_DIR/protected_file" ]; then
    echo "FILE STILL EXISTS - UNEXPECTED (Gap not reproduced?)"
else
    echo "GAP REPRODUCED: FILE DELETED BY UNLINKAT BYPASS!"
fi
