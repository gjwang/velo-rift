#!/bin/bash
# ==============================================================================
# Velo Rift Test Harness Library
# ==============================================================================
# Provides unified logging, counters, and summary functions for all QA v2 tests.
#
# Source this file in test scripts (auto-sourced by test_setup.sh):
#   source "$SCRIPT_DIR/lib/test_harness.sh"
#
# Provides:
#   Logging:
#     log_pass  "message"    - Record a passing test
#     log_fail  "message"    - Record a failing test
#     log_skip  "message"    - Record a skipped test
#     verify_pass "message"  - Alias for log_pass (verify_all compat)
#     verify_fail "message"  - Alias for log_fail (verify_all compat)
#
#   Structure:
#     log_phase   "7: Edge Cases"         - Phase header (prefixes "PHASE")
#     log_section "G1: Toolchain"         - Section header (no prefix)
#     log_test    "P7.1" "description"    - Test case marker
#
#   Summary:
#     print_summary          - Print pass/fail/skip counts
#     exit_with_summary      - Print summary + exit 0 if no fails, else 1
#
#   Variables (read-only access, managed by functions):
#     PASS_COUNT, FAIL_COUNT, SKIP_COUNT
#
#   Options (set before sourcing or before first log call):
#     FAIL_FAST=true         - exit immediately on first failure
# ==============================================================================

# Guard against double-sourcing
if [ "${_TEST_HARNESS_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || true
fi
_TEST_HARNESS_LOADED=1

# ============================================================================
# Counters
# ============================================================================
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# ============================================================================
# Options
# ============================================================================
FAIL_FAST="${FAIL_FAST:-false}"

# ============================================================================
# Logging Functions
# ============================================================================

log_pass() {
    echo "   ✅ PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

log_fail() {
    echo "   ❌ FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    if [ "$FAIL_FAST" = "true" ]; then
        echo "   ⛔ FAIL_FAST enabled — aborting"
        exit_with_summary
    fi
}

log_skip() {
    echo "   ⏭️  SKIP: $1"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

# Aliases for test_vdir_verify_all.sh compatibility
verify_pass() {
    echo "      ✓ $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

verify_fail() {
    echo "      ✗ $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    if [ "$FAIL_FAST" = "true" ]; then
        echo "   ⛔ FAIL_FAST enabled — aborting"
        exit_with_summary
    fi
}

# ============================================================================
# Structure Functions
# ============================================================================

log_phase() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║  PHASE $1"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
}

log_section() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║  $1"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
}

log_test() {
    echo ""
    echo "🧪 [$1] $2"
}

# ============================================================================
# Summary Functions
# ============================================================================

print_summary() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║                         TEST SUMMARY                                  ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "   Passed:  $PASS_COUNT"
    echo "   Failed:  $FAIL_COUNT"
    echo "   Skipped: $SKIP_COUNT"
    echo ""
}

exit_with_summary() {
    print_summary

    if [ "$FAIL_COUNT" -eq 0 ]; then
        echo "✅ ALL TESTS PASSED"
        exit 0
    else
        echo "❌ SOME TESTS FAILED"
        exit 1
    fi
}
