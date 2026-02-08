#!/bin/bash
# Proof of Failure: Symlink Virtualization Gap
# Demonstrates that virtual symlinks resolve correctly under shim.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

SHIM_LIB="$PROJECT_ROOT/target/release/libvrift_inception_layer.dylib"
[ ! -f "$SHIM_LIB" ] && SHIM_LIB="$PROJECT_ROOT/target/debug/libvrift_inception_layer.dylib"

# 1. Setup VFS territory
mkdir -p "$WORK_DIR/vfs"
echo "TARGET CONTENT" > "$WORK_DIR/vfs/target.txt"
ln -s "target.txt" "$WORK_DIR/vfs/link.txt"

# 2. Create C probe for readlink (bypasses SIP restrictions on /usr/bin/readlink)
cat > "$WORK_DIR/readlink_probe.c" << 'PROBE_EOF'
#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <sys/stat.h>

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s readlink|stat|cat <path>\n", argv[0]);
        return 2;
    }
    
    if (strcmp(argv[1], "readlink") == 0) {
        char buf[1024];
        ssize_t len = readlink(argv[2], buf, sizeof(buf) - 1);
        if (len < 0) { perror("readlink"); return 1; }
        buf[len] = '\0';
        printf("%s\n", buf);
    } else if (strcmp(argv[1], "stat") == 0) {
        struct stat sb;
        if (stat(argv[2], &sb) != 0) { perror("stat"); return 1; }
        printf("size=%lld mode=%o\n", (long long)sb.st_size, sb.st_mode & 0777);
    } else if (strcmp(argv[1], "cat") == 0) {
        int fd = open(argv[2], O_RDONLY);
        if (fd < 0) { perror("open"); return 1; }
        char buf[4096];
        ssize_t n;
        while ((n = read(fd, buf, sizeof(buf))) > 0)
            write(1, buf, n);
        close(fd);
    }
    return 0;
}
PROBE_EOF

gcc -O2 -o "$WORK_DIR/probe" "$WORK_DIR/readlink_probe.c"
codesign -s - -f "$WORK_DIR/probe" 2>/dev/null || true
codesign -s - -f "$SHIM_LIB" 2>/dev/null || true

# 3. VRift Inception env
export VRIFT_VFS_PREFIX="$WORK_DIR/vfs"
export VRIFT_PROJECT_ROOT="$WORK_DIR/vfs"
export DYLD_INSERT_LIBRARIES="$SHIM_LIB"
export DYLD_FORCE_FLAT_NAMESPACE=1

PASS=0
FAIL=0

echo "🧪 Case: readlink on virtual symlink"
OUT=$("$WORK_DIR/probe" readlink "$WORK_DIR/vfs/link.txt")
echo "   Result: $OUT"
if [ "$OUT" = "target.txt" ]; then
    echo "✅ Success: Symlink resolved to relative virtual path."
    PASS=$((PASS + 1))
else
    echo "❌ Failure: Symlink resolved to unexpected path: $OUT"
    FAIL=$((FAIL + 1))
fi

echo "🧪 Case: stat -L (follow link via stat)"
set +e
OUT=$("$WORK_DIR/probe" stat "$WORK_DIR/vfs/link.txt")
RET=$?
set -e
echo "   Result: $OUT"
if [ $RET -eq 0 ]; then
    echo "✅ stat follows virtual symlink"
    PASS=$((PASS + 1))
else
    echo "❌ stat failed to follow virtual symlink"
    FAIL=$((FAIL + 1))
fi

echo "🧪 Case: cat through virtual symlink"
set +e
OUT=$("$WORK_DIR/probe" cat "$WORK_DIR/vfs/link.txt")
RET=$?
set -e
if echo "$OUT" | grep -q "TARGET CONTENT"; then
    echo "✅ Success: cat followed virtual symlink."
    PASS=$((PASS + 1))
else
    echo "❌ Failure: cat failed to follow virtual symlink."
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
