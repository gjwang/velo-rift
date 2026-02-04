#!/bin/bash
# test_concurrent_writers.sh
#
# M5 E2E Test: Multiple concurrent rustc processes
# Verifies: No race conditions or corruption with parallel writers

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}M5 E2E Test: test_concurrent_writers${NC}"
echo -e "${YELLOW}========================================${NC}"

# Setup test environment
TEST_WORK="$PROJECT_ROOT/target/e2e_concurrent"
rm -rf "$TEST_WORK"
mkdir -p "$TEST_WORK"
cd "$TEST_WORK"

CONCURRENCY=4
ITERATIONS=5

echo "[1] Creating $CONCURRENCY test source files..."

for i in $(seq 1 $CONCURRENCY); do
    cat > "worker_${i}.rs" << EOF
fn main() {
    println!("Worker $i completed!");
}
EOF
done

echo -e "${GREEN}[1] Created $CONCURRENCY source files${NC}"

# Compile all concurrently
echo "[2] Launching $CONCURRENCY concurrent compilations..."

for iter in $(seq 1 $ITERATIONS); do
    echo "    Iteration $iter..."
    
    pids=()
    for i in $(seq 1 $CONCURRENCY); do
        rustc "worker_${i}.rs" -o "out_${i}" --edition 2021 2>/dev/null &
        pids+=($!)
    done
    
    # Wait for all
    all_passed=true
    for pid in "${pids[@]}"; do
        if ! wait $pid; then
            all_passed=false
        fi
    done
    
    if [ "$all_passed" = false ]; then
        echo -e "${RED}FAIL: Some compilations failed in iteration $iter${NC}"
        exit 1
    fi
done

echo -e "${GREEN}[2] All $((CONCURRENCY * ITERATIONS)) compilations succeeded${NC}"

# Verify all outputs exist and are executable
echo "[3] Verifying outputs..."
for i in $(seq 1 $CONCURRENCY); do
    if [ ! -x "out_${i}" ]; then
        echo -e "${RED}FAIL: out_${i} missing or not executable${NC}"
        exit 1
    fi
    
    OUTPUT=$("./out_${i}")
    if [[ "$OUTPUT" != "Worker $i completed!" ]]; then
        echo -e "${RED}FAIL: out_${i} produced wrong output: $OUTPUT${NC}"
        exit 1
    fi
done

echo -e "${GREEN}[3] All outputs verified${NC}"

# Cleanup
cd "$PROJECT_ROOT"
rm -rf "$TEST_WORK"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}test_concurrent_writers: PASS${NC}"
echo -e "${GREEN}========================================${NC}"
