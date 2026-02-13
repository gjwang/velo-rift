#!/bin/bash
# Test script to detect if fork safety is needed for Velo Rift shim

set -e

echo "=== Fork Safety Detection Test ==="
echo "Testing if fork() causes Worker thread loss..."
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Cleanup
WORK_DIR=$(mktemp -d)
cleanup() {
    rm -rf "$WORK_DIR" 2>/dev/null || true
    rm -f /tmp/test_file_fork_safety.txt 2>/dev/null || true
}
trap cleanup EXIT

cd "$WORK_DIR"

# Create test program that forks and uses VFS
cat > fork_test.c << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/wait.h>

int main() {
    printf("[Parent] PID=%d, testing fork safety...\n", getpid());
    
    // Open a file in parent
    int fd = open("/tmp/test_file_fork_safety.txt", O_RDONLY | O_CREAT, 0644);
    if (fd >= 0) {
        printf("[Parent] Opened FD=%d\n", fd);
        close(fd);
    }
    
    // Fork child processes
    for (int i = 0; i < 10; i++) {
        pid_t pid = fork();
        
        if (pid == 0) {
            // Child process
            printf("[Child %d] PID=%d, attempting VFS operations...\n", i, getpid());
            
            // Try to use fstat (triggers shim)
            struct stat st;
            for (int j = 0; j < 100; j++) {
                int test_fd = open("/tmp/test_file_fork_safety.txt", O_RDONLY);
                if (test_fd >= 0) {
                    fstat(test_fd, &st);
                    close(test_fd);
                }
            }
            
            printf("[Child %d] Completed 100 operations\n", i);
            exit(0);
        } else if (pid < 0) {
            perror("fork");
            exit(1);
        }
    }
    
    // Parent waits for all children
    int status;
    for (int i = 0; i < 10; i++) {
        wait(&status);
    }
    
    printf("[Parent] All children completed\n");
    return 0;
}
EOF

# Compile test program
echo "📝 Compiling test program..."
gcc -o fork_test fork_test.c || {
    echo "❌ Failed to compile test program"
    exit 1
}

# Create test file
touch /tmp/test_file_fork_safety.txt

echo ""
echo "🔬 Running fork test with shim..."
echo "   - 10 child processes"
echo "   - 100 VFS operations per child"
echo "   - Total: 1000 fstat() calls after fork()"
echo ""

# Find shim library using PROJECT_ROOT
if [[ "$(uname)" == "Darwin" ]]; then
    if [ -f "${PROJECT_ROOT}/target/release/libvrift_inception_layer.dylib" ]; then
        SHIM_LIB="${PROJECT_ROOT}/target/release/libvrift_inception_layer.dylib"
    elif [ -f "${PROJECT_ROOT}/target/debug/libvrift_inception_layer.dylib" ]; then
        SHIM_LIB="${PROJECT_ROOT}/target/debug/libvrift_inception_layer.dylib"
    fi
    export DYLD_INSERT_LIBRARIES="$SHIM_LIB"
else
    if [ -f "${PROJECT_ROOT}/target/release/libvrift_shim.so" ]; then
        SHIM_LIB="${PROJECT_ROOT}/target/release/libvrift_shim.so"
    elif [ -f "${PROJECT_ROOT}/target/debug/libvrift_shim.so" ]; then
        SHIM_LIB="${PROJECT_ROOT}/target/debug/libvrift_shim.so"
    fi
    export LD_PRELOAD="$SHIM_LIB"
fi

if [ -n "$SHIM_LIB" ] && [ -f "$SHIM_LIB" ]; then
    echo "✅ Shim library found: $SHIM_LIB"
    
    # Run test with macOS-compatible timeout (perl alarm)
    set +e
    perl -e 'alarm 30; exec @ARGV' bash -c "./fork_test 2>&1 | tee fork_test.log"
    EXIT_CODE=$?
    set -e

    if [ $EXIT_CODE -eq 142 ]; then
        echo "❌ Test timed out!"
        echo "   This may indicate Worker thread loss (tasks piling up)"
        exit 1
    elif [ $EXIT_CODE -ne 0 ]; then
        echo "❌ Test failed with exit code $EXIT_CODE"
        exit 1
    fi
    
    echo ""
    echo "=== Analysis ==="
    
    # Check for errors in log
    if grep -qi "error\|leak\|full\|timeout" fork_test.log; then
        echo "⚠️  Detected errors in output:"
        grep -i "error\|leak\|full\|timeout" fork_test.log
        echo ""
        echo "❌ FORK SAFETY REQUIRED!"
        echo "   Reason: Errors detected during fork test"
        exit 1
    fi
    
    # Check if all children completed
    COMPLETED=$(grep -c "Child.*Completed" fork_test.log || echo 0)
    if [ "$COMPLETED" -ne 10 ]; then
        echo "❌ FORK SAFETY REQUIRED!"
        echo "   Reason: Only $COMPLETED/10 children completed"
        echo "   Worker threads likely lost in child processes"
        exit 1
    fi
    
    echo "✅ All 10 children completed successfully"
    echo "✅ No errors detected"
    echo ""
    echo "✅ FORK SAFETY NOT REQUIRED (currently)"
    echo "   Your workload does not exhibit fork-related issues"
    
else
    echo "⚠️  Shim library not found, running without shim..."
    ./fork_test
    echo ""
    echo "ℹ️  Test completed without shim (baseline)"
    echo "   Build vrift-inception-layer first to test with shim"
fi

echo ""
echo "=== Summary ==="
echo "Test completed. Check results above."
