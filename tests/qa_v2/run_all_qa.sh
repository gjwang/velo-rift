#!/usr/bin/env bash
# run_all_qa.sh — Parallel QA test suite runner with result summary
#
# Usage:
#   ./tests/qa_v2/run_all_qa.sh          # run all tests (4 in parallel)
#   ./tests/qa_v2/run_all_qa.sh -j8      # run 8 in parallel
#   ./tests/qa_v2/run_all_qa.sh -f test_value  # filter by name pattern
#   ./tests/qa_v2/run_all_qa.sh --list    # list available tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Defaults
PARALLEL=4
FILTER=""
LIST_ONLY=false
RESULTS_DIR=""

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        -j*)   PARALLEL="${1#-j}"; shift ;;
        -f)    FILTER="$2"; shift 2 ;;
        --list) LIST_ONLY=true; shift ;;
        *)     echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# Discover tests
TESTS=()
for f in "$SCRIPT_DIR"/test_*.sh; do
    [[ "$(basename "$f")" == "test_setup.sh" ]] && continue
    [[ "$(basename "$f")" == "test_harness.sh" ]] && continue
    if [[ -n "$FILTER" ]] && ! echo "$(basename "$f")" | grep -q "$FILTER"; then
        continue
    fi
    TESTS+=("$f")
done

if $LIST_ONLY; then
    echo "Available QA tests (${#TESTS[@]}):"
    for t in "${TESTS[@]}"; do
        echo "  $(basename "$t")"
    done
    exit 0
fi

# Setup results directory
RESULTS_DIR="$(mktemp -d /tmp/vrift_qa_results_XXXXXX)"
trap 'rm -rf "$RESULTS_DIR"' EXIT

echo "╔══════════════════════════════════════════════════╗"
echo "║  🧪 Velo Rift QA Suite                          ║"
echo "║  Tests: ${#TESTS[@]}  Parallel: $PARALLEL                    ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# Build release first if needed
if [[ ! -f "$ROOT_DIR/target/release/vrift" ]]; then
    echo "⚙️  Building release binaries..."
    (cd "$ROOT_DIR" && cargo build --release -p vrift-cli -p vrift-daemon 2>/dev/null)
fi

# Run tests in parallel
START_TIME=$(date +%s)
RUNNING=0
PIDS=()
TEST_NAMES=()

run_test() {
    local test_script="$1"
    local test_name
    test_name="$(basename "$test_script" .sh)"
    local log_file="$RESULTS_DIR/${test_name}.log"

    (
        if timeout 120 bash "$test_script" > "$log_file" 2>&1; then
            echo "PASS" > "$RESULTS_DIR/${test_name}.result"
        else
            echo "FAIL" > "$RESULTS_DIR/${test_name}.result"
        fi
    ) &
    PIDS+=($!)
    TEST_NAMES+=("$test_name")
}

# Launch tests with parallelism control
for test_script in "${TESTS[@]}"; do
    # Wait if at capacity
    while [[ ${#PIDS[@]} -ge $PARALLEL ]]; do
        NEW_PIDS=()
        NEW_NAMES=()
        for i in "${!PIDS[@]}"; do
            if kill -0 "${PIDS[$i]}" 2>/dev/null; then
                NEW_PIDS+=("${PIDS[$i]}")
                NEW_NAMES+=("${TEST_NAMES[$i]}")
            else
                # Process finished, print inline result
                wait "${PIDS[$i]}" 2>/dev/null || true
                name="${TEST_NAMES[$i]}"
                result="$(cat "$RESULTS_DIR/${name}.result" 2>/dev/null || echo "UNKNOWN")"
                if [[ "$result" == "PASS" ]]; then
                    printf "  ✅ %-40s %s\n" "$name" "PASS"
                else
                    printf "  ❌ %-40s %s\n" "$name" "FAIL"
                fi
            fi
        done
        PIDS=("${NEW_PIDS[@]+"${NEW_PIDS[@]}"}")
        TEST_NAMES=("${NEW_NAMES[@]+"${NEW_NAMES[@]}"}")
        [[ ${#PIDS[@]} -ge $PARALLEL ]] && sleep 0.5
    done
    run_test "$test_script"
done

# Wait for remaining
for i in "${!PIDS[@]}"; do
    wait "${PIDS[$i]}" 2>/dev/null || true
    name="${TEST_NAMES[$i]}"
    result="$(cat "$RESULTS_DIR/${name}.result" 2>/dev/null || echo "UNKNOWN")"
    if [[ "$result" == "PASS" ]]; then
        printf "  ✅ %-40s %s\n" "$name" "PASS"
    else
        printf "  ❌ %-40s %s\n" "$name" "FAIL"
    fi
done

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Summary
echo ""
echo "─────────────────────────────────────────────────"

PASS_COUNT=0
FAIL_COUNT=0
FAIL_LIST=()

for f in "$RESULTS_DIR"/*.result; do
    [[ ! -f "$f" ]] && continue
    name="$(basename "$f" .result)"
    result="$(cat "$f")"
    if [[ "$result" == "PASS" ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_LIST+=("$name")
    fi
done

echo "  ✅ $PASS_COUNT passed   ❌ $FAIL_COUNT failed   ⏱ ${ELAPSED}s"

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo ""
    echo "  Failed tests:"
    for name in "${FAIL_LIST[@]}"; do
        echo "    • $name"
        # Show last 3 lines of log
        tail -3 "$RESULTS_DIR/${name}.log" 2>/dev/null | sed 's/^/      /'
    done
    echo ""
    echo "  Full logs: $RESULTS_DIR/"
    # Don't clean up on failure
    trap - EXIT
    exit 1
fi

echo ""
echo "  🏆 All tests passed!"
