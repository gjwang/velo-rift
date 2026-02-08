#!/bin/bash
# Gap Test: mkdirat bypass via file descriptor
# Proves that mkdirat can create directories even when path-based mkdir is shimmed.
set -e
source "$(dirname "${BASH_SOURCE[0]}")/../helpers/test_common.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# SSOT: prefer release, fallback to debug
SHIM_LIB="${PROJECT_ROOT}/target/release/libvrift_inception_layer.dylib"
[ ! -f "$SHIM_LIB" ] && SHIM_LIB="${PROJECT_ROOT}/target/debug/libvrift_inception_layer.dylib"

WORK_DIR=$(mktemp -d)
trap 'safe_rm "$WORK_DIR"' EXIT

# Inline: test_mkdir_shim — path-based mkdir (should be blocked by shim)
cat > "$WORK_DIR/test_mkdir_shim.c" << 'EOF'
#include <stdio.h>
#include <sys/stat.h>
#include <errno.h>
#include <string.h>
int main(int argc, char *argv[]) {
    if (argc < 2) return 1;
    int ret = mkdir(argv[1], 0755);
    printf("mkdir result: %d (%s)\n", ret, ret == 0 ? "success" : strerror(errno));
    return ret;
}
EOF
cc -O2 -o "$WORK_DIR/test_mkdir_shim" "$WORK_DIR/test_mkdir_shim.c"

# Inline: test_mkdirat_gap — fd-based mkdirat (bypasses path check)
cat > "$WORK_DIR/test_mkdirat_gap.c" << 'EOF'
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
#include <string.h>
int main(int argc, char *argv[]) {
    if (argc < 2) return 1;
    int dirfd = open(".", O_RDONLY | O_DIRECTORY);
    if (dirfd < 0) { perror("open dir"); return 1; }
    int ret = mkdirat(dirfd, argv[1], 0755);
    printf("mkdirat result: %d (%s)\n", ret, ret == 0 ? "success" : strerror(errno));
    close(dirfd);
    return ret;
}
EOF
cc -O2 -o "$WORK_DIR/test_mkdirat_gap" "$WORK_DIR/test_mkdirat_gap.c"

export VRIFT_VFS_PREFIX="$WORK_DIR"

echo "Using VRIFT_VFS_PREFIX=$VRIFT_VFS_PREFIX"

echo -e "\n1. Testing shimmed mkdir (C program):"
DYLD_INSERT_LIBRARIES="$SHIM_LIB" \
DYLD_FORCE_FLAT_NAMESPACE=1 \
"$WORK_DIR/test_mkdir_shim" "$WORK_DIR/new_dir" || true

if [ ! -d "$WORK_DIR/new_dir" ]; then
    echo "DIR DOES NOT EXIST - OK (Mkdir was blocked)"
else
    echo "BUG: DIR CREATED BY MKDIR! (Shim not working?)"
fi

echo -e "\n2. Testing UNSHIMMED mkdirat (C program):"
DYLD_INSERT_LIBRARIES="$SHIM_LIB" \
DYLD_FORCE_FLAT_NAMESPACE=1 \
"$WORK_DIR/test_mkdirat_gap" "$WORK_DIR/new_dir_at" || true

if [ -d "$WORK_DIR/new_dir_at" ]; then
    echo "GAP REPRODUCED: DIR CREATED BY MKDIRAT BYPASS!"
else
    echo "DIR DOES NOT EXIST - UNEXPECTED"
fi
