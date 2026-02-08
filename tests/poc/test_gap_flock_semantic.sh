#!/bin/bash
# RFC-0049 Gap Test: flock() Semantic Isolation
#
# Verifies that flock() works correctly under the shim:
# Process A holds exclusive lock for 1500ms
# Process B tries to acquire — should block until A releases

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "=== P0 Gap Test: flock() Semantic Isolation ==="
echo ""

# Setup isolated temp directory
TEST_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

echo "[1] Compiling test helper..."
cat > "$TEST_DIR/flock_test.c" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/time.h>
#include <errno.h>

long current_ms() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

int main(int argc, char *argv[]) {
    if (argc < 5) {
        fprintf(stderr, "Usage: %s <file> <op> <sleep_ms> <signal_file>\n", argv[0]);
        return 1;
    }

    const char *path = argv[1];
    int op = atoi(argv[2]); // 2=EX, 1=SH, 8=UN
    int sleep_ms = atoi(argv[3]);
    const char *signal_file = argv[4];

    int fd = open(path, O_RDWR | O_CREAT, 0666);
    if (fd < 0) { perror("open"); return 1; }

    long t0 = current_ms();
    if (flock(fd, op) != 0) { perror("flock"); return 1; }
    long t1 = current_ms();
    printf("PID %d: Acquired lock in %ld ms\n", getpid(), t1 - t0);

    // Signal that we have the lock
    if (signal_file[0] != '-') {
        int sf = open(signal_file, O_WRONLY | O_CREAT | O_TRUNC, 0666);
        if (sf >= 0) { write(sf, "locked\n", 7); close(sf); }
    }

    if (sleep_ms > 0) usleep(sleep_ms * 1000);

    flock(fd, LOCK_UN);
    close(fd);
    return 0;
}
EOF

gcc -O2 -o "$TEST_DIR/flock_test" "$TEST_DIR/flock_test.c"
codesign -s - -f "$TEST_DIR/flock_test" 2>/dev/null || true

# Use release shim if available
SHIM_LIB="${PROJECT_ROOT}/target/release/libvrift_inception_layer.dylib"
[ ! -f "$SHIM_LIB" ] && SHIM_LIB="${PROJECT_ROOT}/target/debug/libvrift_inception_layer.dylib"
codesign -s - -f "$SHIM_LIB" 2>/dev/null || true

echo ""
echo "[2] Running functional test..."

# Create test file
TEST_FILE="$TEST_DIR/lock.txt"
touch "$TEST_FILE"
SIGNAL_FILE="$TEST_DIR/lock_acquired"

# Run under shim
export DYLD_INSERT_LIBRARIES="$SHIM_LIB"
export DYLD_FORCE_FLAT_NAMESPACE=1
export VRIFT_PROJECT_ROOT="$TEST_DIR"
export VRIFT_VFS_PREFIX="$TEST_DIR"

# Process A: Hold exclusive lock for 1500ms, then signal
"$TEST_DIR/flock_test" "$TEST_FILE" 2 1500 "$SIGNAL_FILE" &
PID_A=$!

# Wait for A to signal that it has acquired the lock (max 3 seconds)
for i in $(seq 1 30); do
    if [ -f "$SIGNAL_FILE" ]; then
        break
    fi
    sleep 0.1
done

if [ ! -f "$SIGNAL_FILE" ]; then
    echo "❌ ERROR: Process A never acquired the lock"
    kill $PID_A 2>/dev/null || true
    exit 1
fi

# Process B: Try to acquire exclusively — should block until A releases
"$TEST_DIR/flock_test" "$TEST_FILE" 2 0 "-" > "$TEST_DIR/output_b.txt" 2>&1

wait $PID_A 2>/dev/null || true

# Analyze Output
echo ""
cat "$TEST_DIR/output_b.txt"
WAIT_MS=$(grep "Acquired lock in" "$TEST_DIR/output_b.txt" | awk '{print $6}')

if [ -z "$WAIT_MS" ]; then
    echo "❌ ERROR: Could not parse wait time from output"
    exit 1
fi

echo "Process B waited: ${WAIT_MS} ms"

if [ "$WAIT_MS" -gt 500 ] 2>/dev/null; then
    echo "✅ PASS: Flock blocking behavior confirmed (> 500ms wait)"
    exit 0
else
    echo "❌ FAIL: Flock acquired too quickly (Wait: ${WAIT_MS} ms). Isolation might be broken."
    exit 1
fi
