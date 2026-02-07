#!/bin/bash
# Gap Test: fchmod bypass via file descriptor
# Proves that fchmod can change permissions even when path-based chmod is shimmed.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# SSOT: prefer release, fallback to debug
SHIM_LIB="${PROJECT_ROOT}/target/release/libvrift_inception_layer.dylib"
[ ! -f "$SHIM_LIB" ] && SHIM_LIB="${PROJECT_ROOT}/target/debug/libvrift_inception_layer.dylib"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

touch "$WORK_DIR/protected_file"
chmod 644 "$WORK_DIR/protected_file"

# Inline: test_chmod_shim — path-based chmod (should be blocked by shim)
cat > "$WORK_DIR/test_chmod_shim.c" << 'EOF'
#include <stdio.h>
#include <sys/stat.h>
#include <errno.h>
#include <string.h>
int main(int argc, char *argv[]) {
    if (argc < 2) return 1;
    int ret = chmod(argv[1], 0000);
    printf("chmod result: %d (%s)\n", ret, ret == 0 ? "success" : strerror(errno));
    return ret;
}
EOF
cc -O2 -o "$WORK_DIR/test_chmod_shim" "$WORK_DIR/test_chmod_shim.c"

# Inline: test_fchmod_gap — fd-based fchmod (bypasses path check)
cat > "$WORK_DIR/test_fchmod_gap.c" << 'EOF'
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
#include <string.h>
int main(int argc, char *argv[]) {
    if (argc < 2) return 1;
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    int ret = fchmod(fd, 0000);
    printf("fchmod result: %d (%s)\n", ret, ret == 0 ? "success" : strerror(errno));
    close(fd);
    return ret;
}
EOF
cc -O2 -o "$WORK_DIR/test_fchmod_gap" "$WORK_DIR/test_fchmod_gap.c"

export VRIFT_VFS_PREFIX="$WORK_DIR"

echo "Using VRIFT_VFS_PREFIX=$VRIFT_VFS_PREFIX"

echo -e "\n1. Testing shimmed chmod (path-based C program):"
DYLD_INSERT_LIBRARIES="$SHIM_LIB" \
DYLD_FORCE_FLAT_NAMESPACE=1 \
"$WORK_DIR/test_chmod_shim" "$WORK_DIR/protected_file" || true

# Verify permissions
current_mode=$(stat -f "%Lp" "$WORK_DIR/protected_file")
echo "Current mode: $current_mode"
if [ "$current_mode" == "644" ]; then
    echo "FILE MODE UNCHANGED - OK (Chmod was blocked)"
else
    echo "BUG: FILE MODE CHANGED BY CHMOD! (Shim not working?)"
fi

echo -e "\n2. Testing UNSHIMMED fchmod (descriptor-based C program):"
chmod 644 "$WORK_DIR/protected_file"
DYLD_INSERT_LIBRARIES="$SHIM_LIB" \
DYLD_FORCE_FLAT_NAMESPACE=1 \
"$WORK_DIR/test_fchmod_gap" "$WORK_DIR/protected_file" || true

final_mode=$(stat -f "%Lp" "$WORK_DIR/protected_file")
echo "Final mode: $final_mode"
if [ "$final_mode" == "0" ]; then
    echo "GAP REPRODUCED: FILE MODE CHANGED BY FCHMOD BYPASS!"
else
    echo "FILE MODE UNCHANGED - UNEXPECTED"
fi
