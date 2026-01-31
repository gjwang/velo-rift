#!/bin/bash
# Multi-Tier Parallel Ingest Benchmark
#
# Tests parallel ingest performance across small/medium/large datasets.
#
# Usage:
#   ./scripts/benchmark_parallel.sh [--size small|medium|large|all]
#
# Results compare 1-thread vs 4-thread performance.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BENCH_DIR="/tmp/vrift-bench"

# Parse arguments
SIZE="${1:-all}"
[[ "$SIZE" == "--size" ]] && SIZE="${2:-all}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Vrift Parallel Ingest Benchmark ===${NC}"
echo ""

# Build release binary
echo "[1/5] Building release binary..."
cargo build --release -p vrift-cli --quiet

VRIFT="$PROJECT_ROOT/target/release/vrift"

run_benchmark() {
    local name=$1
    local package_json=$2
    local work_dir="$BENCH_DIR/$name"
    
    echo -e "\n${YELLOW}--- $name ---${NC}"
    
    # Setup
    rm -rf "$work_dir"
    mkdir -p "$work_dir"
    cp "$package_json" "$work_dir/package.json"
    
    echo "Installing npm dependencies..."
    cd "$work_dir"
    npm install --silent --legacy-peer-deps 2>/dev/null || npm install --silent 2>/dev/null
    
    FILE_COUNT=$(find node_modules -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "Files: $FILE_COUNT"
    
    # Benchmark 1 thread
    rm -rf node_modules/.vrift
    CAS1=$(mktemp -d)
    echo -n "1 thread: "
    TIME1=$( { time "$VRIFT" --cas-root "$CAS1" ingest node_modules -j 1 -o /tmp/m1.bin 2>&1; } 2>&1 | grep real | awk '{print $2}' )
    echo "$TIME1"
    
    # Benchmark 4 threads
    rm -rf node_modules/.vrift
    CAS4=$(mktemp -d)
    echo -n "4 threads: "
    TIME4=$( { time "$VRIFT" --cas-root "$CAS4" ingest node_modules -j 4 -o /tmp/m4.bin 2>&1; } 2>&1 | grep real | awk '{print $2}' )
    echo "$TIME4"
    
    # Cleanup
    rm -rf "$CAS1" "$CAS4"
    
    echo -e "${GREEN}✓ $name complete${NC}"
}

# Run benchmarks based on size
case "$SIZE" in
    small)
        run_benchmark "small" "$PROJECT_ROOT/examples/benchmarks/small_package.json"
        ;;
    medium)
        run_benchmark "medium" "$PROJECT_ROOT/examples/benchmarks/medium_package.json"
        ;;
    large)
        run_benchmark "large" "$PROJECT_ROOT/examples/benchmarks/large_package.json"
        ;;
    xlarge)
        run_benchmark "xlarge" "$PROJECT_ROOT/examples/benchmarks/xlarge_package.json"
        ;;
    all)
        run_benchmark "small" "$PROJECT_ROOT/examples/benchmarks/small_package.json"
        run_benchmark "medium" "$PROJECT_ROOT/examples/benchmarks/medium_package.json"
        run_benchmark "large" "$PROJECT_ROOT/examples/benchmarks/large_package.json"
        run_benchmark "xlarge" "$PROJECT_ROOT/examples/benchmarks/xlarge_package.json"
        ;;
    *)
        echo "Unknown size: $SIZE"
        echo "Usage: $0 [--size small|medium|large|xlarge|all]"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}=== Benchmark Complete ===${NC}"
