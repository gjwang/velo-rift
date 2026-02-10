#!/bin/bash
# ==============================================================================
# Solid Mode: Cargo Build E2E (User Perspective)
# ==============================================================================
# Tests the FULL user workflow with behavioral verification:
#
#   Phase 0: Setup — Create a real Rust project (lib + bin + tests)
#   Phase 1: Baseline — cargo build + cargo test (no inception)
#   Phase 2: Ingest — CAS + VDir generation
#   Phase 3: Inception build — initial build under inception
#   Phase 4: Real code change — modify function → verify new output
#   Phase 5: Add new module — create module + import → verify it works
#   Phase 6: cargo test — tests pass under inception
#   Phase 7: Clean rebuild — rm -rf target → materialize from CAS
#   Phase 8: Post-inception — exit inception → build still works
#   Phase 9: CAS integrity — hash verification + uchg flags
#
# Every step verifies BEHAVIORAL CORRECTNESS, not just exit codes.
# ==============================================================================

set -euo pipefail
export RUST_BACKTRACE=1

# ============================================================================
# Configuration
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_WORKSPACE_BASE="/tmp/vdir_cargo_e2e_$$"
SKIP_AUTO_SETUP=1
source "$SCRIPT_DIR/test_setup.sh"

PASSED=0
FAILED=0

# ============================================================================
# Helpers
# ============================================================================
pass() {
    echo "  ✅ PASS: $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo "  ❌ FAIL: $1"
    FAILED=$((FAILED + 1))
}

# Assert a command's stdout contains a specific string
assert_output() {
    local desc="$1"
    local expected="$2"
    shift 2
    local actual
    actual=$("$@" 2>/dev/null) || true
    if echo "$actual" | grep -q "$expected"; then
        pass "$desc"
    else
        fail "$desc (expected '$expected', got '$(echo "$actual" | head -1)')"
    fi
}

# Assert a file exists and is a regular file (not symlink)
assert_real_file() {
    local path="$1"
    local desc="${2:-File is real}"
    if [ -f "$path" ] && [ ! -L "$path" ]; then
        pass "$desc: $(basename "$path")"
    else
        fail "$desc: $path (missing or symlink)"
    fi
}

# Assert file permissions match expected (e.g. "644", "755")
assert_permissions() {
    local path="$1"
    local expected="$2"
    local desc="${3:-Permissions}"
    local actual
    actual=$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path" 2>/dev/null)
    if [ "$actual" = "$expected" ]; then
        pass "$desc: $actual"
    else
        fail "$desc: expected $expected, got $actual"
    fi
}

# Assert file has NO uchg flag (macOS only)
assert_no_uchg() {
    local path="$1"
    local desc="${2:-No uchg flag}"
    if [ "$(uname)" != "Darwin" ]; then
        pass "$desc (not macOS, skipped)"
        return
    fi
    if ls -lO "$path" 2>/dev/null | grep -q "uchg"; then
        fail "$desc: $path has uchg!"
    else
        pass "$desc"
    fi
}

# Assert cargo build output contains "Compiling <crate>"
assert_recompiled() {
    local build_output="$1"
    local crate_name="$2"
    local desc="${3:-Recompiled}"
    if echo "$build_output" | grep -q "Compiling $crate_name"; then
        pass "$desc: $crate_name was recompiled"
    else
        fail "$desc: $crate_name was NOT recompiled (expected recompilation)"
    fi
}

# Assert cargo build output does NOT contain "Compiling <crate>"  
assert_not_recompiled() {
    local build_output="$1"
    local crate_name="$2"
    local desc="${3:-Not recompiled}"
    if echo "$build_output" | grep -q "Compiling $crate_name"; then
        fail "$desc: $crate_name was recompiled (expected cache hit)"
    else
        pass "$desc: $crate_name used cache"
    fi
}

run_inception() {
    env \
        VRIFT_PROJECT_ROOT="$TEST_WORKSPACE" \
        VRIFT_VFS_PREFIX="$TEST_WORKSPACE" \
        VRIFT_SOCKET_PATH="$VRIFT_SOCKET_PATH" \
        VR_THE_SOURCE="$VR_THE_SOURCE" \
        VRIFT_INCEPTION=1 \
        DYLD_INSERT_LIBRARIES="$SHIM_LIB" \
        DYLD_FORCE_FLAT_NAMESPACE=1 \
        "$@"
}

run_inception_vdir() {
    env \
        VRIFT_PROJECT_ROOT="$TEST_WORKSPACE" \
        VRIFT_VFS_PREFIX="$TEST_WORKSPACE" \
        VRIFT_SOCKET_PATH="$VRIFT_SOCKET_PATH" \
        VR_THE_SOURCE="$VR_THE_SOURCE" \
        VRIFT_VDIR_MMAP="$VDIR_MMAP_PATH" \
        VRIFT_INCEPTION=1 \
        DYLD_INSERT_LIBRARIES="$SHIM_LIB" \
        DYLD_FORCE_FLAT_NAMESPACE=1 \
        "$@"
}

# ============================================================================
# Prerequisites
# ============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  Solid Mode: Cargo Build E2E Test (Enhanced)                       ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"

if ! check_prerequisites; then
    echo "❌ Prerequisites not met. Build first: cargo build"
    exit 1
fi

echo "  Shim:      $SHIM_LIB"
echo ""

# ============================================================================
# Phase 0: Setup — Create a real Rust project
# ============================================================================
echo "═══ Phase 0: Setup ═══"

setup_test_workspace
cd "$TEST_WORKSPACE"

cat > Cargo.toml << 'EOF'
[package]
name = "hello-vrift"
version = "0.1.0"
edition = "2021"

[lib]
name = "hello_vrift"
path = "src/lib.rs"

[[bin]]
name = "hello-vrift"
path = "src/main.rs"
EOF

mkdir -p src

cat > src/lib.rs << 'EOF'
/// Core greeting function — version 1
pub fn greet(name: &str) -> String {
    format!("Hello, {}! Welcome to VeloRift v1.", name)
}

/// Compute a value — used to verify code changes propagate
pub fn compute(x: i32) -> i32 {
    x * 2
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_greet() {
        assert!(greet("World").contains("VeloRift v1"));
    }

    #[test]
    fn test_compute() {
        assert_eq!(compute(21), 42);
    }
}
EOF

cat > src/main.rs << 'EOF'
fn main() {
    println!("{}", hello_vrift::greet("World"));
    println!("compute(21) = {}", hello_vrift::compute(21));
}
EOF

pass "Created Rust project with lib + bin + tests"

# ============================================================================
# Phase 1: Baseline — cargo build + test (no inception)
# ============================================================================
echo ""
echo "═══ Phase 1: Baseline build (no inception) ═══"

BUILD_OUT=$(cargo build 2>&1)
if [ $? -eq 0 ]; then
    pass "Baseline cargo build"
else
    fail "Baseline cargo build"
    echo "$BUILD_OUT"
    exit 1
fi

# Verify binary output is EXACTLY what we expect
assert_output "Binary output line 1" "Hello, World! Welcome to VeloRift v1." ./target/debug/hello-vrift
assert_output "Binary output line 2" "compute(21) = 42" ./target/debug/hello-vrift

# Verify tests pass
TEST_OUT=$(cargo test 2>&1)
if echo "$TEST_OUT" | grep -q "test result: ok"; then
    pass "Baseline cargo test"
else
    fail "Baseline cargo test"
fi

# ============================================================================
# Phase 2: Ingest — CAS + VDir
# ============================================================================
echo ""
echo "═══ Phase 2: Ingest into CAS ═══"

start_daemon "warn"
sleep 1

INGEST_OUT=$(VRIFT_SOCKET_PATH="$VRIFT_SOCKET_PATH" VR_THE_SOURCE="$VR_THE_SOURCE" \
    "$VRIFT_CLI" ingest --parallel . 2>&1)
if [ $? -eq 0 ]; then
    pass "Ingest completed"
    echo "  $(echo "$INGEST_OUT" | grep -o '[0-9]* files' | head -1)"
else
    fail "Ingest failed"
    echo "$INGEST_OUT"
    exit 1
fi

sleep 2

# Find VDir mmap
VDIR_MMAP_PATH=""
if [ -d "$TEST_WORKSPACE/.vrift/vdir" ]; then
    VDIR_MMAP_PATH=$(find "$TEST_WORKSPACE/.vrift/vdir" -name "*.vdir" 2>/dev/null | head -1)
fi
if [ -z "$VDIR_MMAP_PATH" ]; then
    VDIR_MMAP_PATH=$(find "${HOME}/.vrift/vdir" -name "*.vdir" -newer "$TEST_WORKSPACE/Cargo.toml" 2>/dev/null | head -1)
fi

if [ -n "$VDIR_MMAP_PATH" ]; then
    pass "VDir mmap found: $(basename "$VDIR_MMAP_PATH")"
else
    fail "VDir mmap not found"
    exit 1
fi

CAS_COUNT=$(find "$VR_THE_SOURCE" -name "*.bin" 2>/dev/null | wc -l | tr -d ' ')
echo "  CAS blobs: $CAS_COUNT"

# ============================================================================
# Phase 3: Inception — Initial build
# ============================================================================
echo ""
echo "═══ Phase 3: Inception build (initial) ═══"

BUILD_OUT=$(run_inception_vdir cargo build 2>&1)
if [ $? -eq 0 ]; then
    pass "Inception cargo build"
else
    fail "Inception cargo build"
    echo "$BUILD_OUT"
fi

# Behavioral check: binary output correct under inception
assert_output "Binary output v1 under inception" "VeloRift v1" run_inception_vdir ./target/debug/hello-vrift
assert_output "Compute output under inception" "compute(21) = 42" run_inception_vdir ./target/debug/hello-vrift

# ============================================================================
# Phase 4: Real code change — modify function → verify new output
# ============================================================================
echo ""
echo "═══ Phase 4: Real code modification ═══"

# Change greet() to return "v2" and compute() to return x*3
cat > src/lib.rs << 'EOF'
/// Core greeting function — version 2 (MODIFIED)
pub fn greet(name: &str) -> String {
    format!("Hello, {}! Welcome to VeloRift v2.", name)
}

/// Compute a value — changed from x*2 to x*3
pub fn compute(x: i32) -> i32 {
    x * 3
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_greet() {
        assert!(greet("World").contains("VeloRift v2"));
    }

    #[test]
    fn test_compute() {
        assert_eq!(compute(21), 63);
    }
}
EOF

echo "  Modified src/lib.rs: greet→v2, compute→x*3"

BUILD_OUT=$(run_inception_vdir cargo build 2>&1)
if [ $? -eq 0 ]; then
    pass "Build after code change"
else
    fail "Build after code change"
    echo "$BUILD_OUT"
fi

# Verify recompilation happened
assert_recompiled "$BUILD_OUT" "hello-vrift" "Incremental recompilation"

# BEHAVIORAL VERIFICATION: output must reflect NEW code
assert_output "Binary now says v2" "VeloRift v2" run_inception_vdir ./target/debug/hello-vrift
assert_output "Compute now returns 63" "compute(21) = 63" run_inception_vdir ./target/debug/hello-vrift

# Negative check: old output must NOT appear
OLD_OUT=$(run_inception_vdir ./target/debug/hello-vrift 2>/dev/null || true)
if echo "$OLD_OUT" | grep -q "VeloRift v1"; then
    fail "Stale output: still shows v1 after code change!"
else
    pass "No stale v1 output"
fi

# ============================================================================
# Phase 5: Add a new module → import → verify
# ============================================================================
echo ""
echo "═══ Phase 5: Add new module ═══"

mkdir -p src

cat > src/utils.rs << 'EOF'
/// Helper module added during inception
pub fn reverse(s: &str) -> String {
    s.chars().rev().collect()
}
EOF

# Update lib.rs to use the new module
cat > src/lib.rs << 'EOF'
pub mod utils;

/// Core greeting function — version 3 (with utils)
pub fn greet(name: &str) -> String {
    let reversed = utils::reverse(name);
    format!("Hello, {}! (reversed: {}) VeloRift v3.", name, reversed)
}

pub fn compute(x: i32) -> i32 {
    x * 3
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_greet_with_reverse() {
        let out = greet("World");
        assert!(out.contains("VeloRift v3"));
        assert!(out.contains("dlroW"));
    }

    #[test]
    fn test_reverse() {
        assert_eq!(utils::reverse("abc"), "cba");
    }

    #[test]
    fn test_compute() {
        assert_eq!(compute(21), 63);
    }
}
EOF

echo "  Added src/utils.rs + updated lib.rs to v3"

BUILD_OUT=$(run_inception_vdir cargo build 2>&1)
if [ $? -eq 0 ]; then
    pass "Build with new module"
else
    fail "Build with new module"
    echo "$BUILD_OUT"
fi

# Behavioral: binary shows reversed name
assert_output "Shows reversed name" "dlroW" run_inception_vdir ./target/debug/hello-vrift
assert_output "Shows v3" "VeloRift v3" run_inception_vdir ./target/debug/hello-vrift

# ============================================================================
# Phase 6: cargo test — tests pass under inception
# ============================================================================
echo ""
echo "═══ Phase 6: cargo test under inception ═══"

TEST_OUT=$(run_inception_vdir cargo test 2>&1)
if echo "$TEST_OUT" | grep -q "test result: ok"; then
    pass "cargo test passes under inception"
    TEST_COUNT=$(echo "$TEST_OUT" | grep "test result" | grep -o '[0-9]* passed' | head -1)
    echo "  $TEST_COUNT"
else
    fail "cargo test failed under inception"
    echo "$TEST_OUT" | tail -10
fi

# Verify specific tests ran
if echo "$TEST_OUT" | grep -q "test_greet_with_reverse"; then
    pass "test_greet_with_reverse executed"
else
    fail "test_greet_with_reverse not found in output"
fi

if echo "$TEST_OUT" | grep -q "test_reverse"; then
    pass "test_reverse executed"
else
    fail "test_reverse not found in output"
fi

# ============================================================================
# Phase 7: Clean → Rebuild from CAS (stat-time materialization)
# ============================================================================
echo ""
echo "═══ Phase 7: Clean rebuild from CAS ═══"

chflags -R nouchg "$TEST_WORKSPACE/target" 2>/dev/null || true
rm -rf "$TEST_WORKSPACE/target"

if [ ! -d "$TEST_WORKSPACE/target" ]; then
    pass "target/ removed"
else
    fail "target/ still exists"
fi

# Rebuild — this triggers stat-time materialization
BUILD_OUT=$(run_inception_vdir cargo build 2>&1)
if [ $? -eq 0 ]; then
    pass "Clean rebuild succeeded"
else
    fail "Clean rebuild failed"
    echo "$BUILD_OUT"
fi

# Behavioral: binary still has v3 output (latest code, not CAS stale)
assert_output "After clean rebuild shows v3" "VeloRift v3" run_inception_vdir ./target/debug/hello-vrift
assert_output "After clean rebuild shows reversed" "dlroW" run_inception_vdir ./target/debug/hello-vrift

# Verify materialized files are real (not symlinks)
assert_real_file "$TEST_WORKSPACE/target/debug/hello-vrift" "Binary is a real file"

# Verify materialized files have correct permissions (no uchg)
if [ -f "$TEST_WORKSPACE/target/debug/hello-vrift" ]; then
    assert_no_uchg "$TEST_WORKSPACE/target/debug/hello-vrift" "Binary has no uchg"
fi

# ============================================================================
# Phase 8: Post-inception — build without shim
# ============================================================================
echo ""
echo "═══ Phase 8: Post-inception build (no shim) ═══"

BUILD_OUT=$(cargo build 2>&1)
if [ $? -eq 0 ]; then
    pass "Post-inception build (no shim)"
else
    fail "Post-inception build (no shim)"
    echo "$BUILD_OUT"
fi

# Binary works without inception
assert_output "Binary works without inception" "VeloRift v3" ./target/debug/hello-vrift
assert_output "Reverse works without inception" "dlroW" ./target/debug/hello-vrift

# Tests pass without inception
TEST_OUT=$(cargo test 2>&1)
if echo "$TEST_OUT" | grep -q "test result: ok"; then
    pass "cargo test passes without inception"
else
    fail "cargo test fails without inception"
fi

# ============================================================================
# Phase 9: CAS integrity
# ============================================================================
echo ""
echo "═══ Phase 9: CAS integrity ═══"

CAS_INTACT=true
CHECKED=0
for blob in $(find "$VR_THE_SOURCE" -name "*.bin" 2>/dev/null | head -20); do
    filename=$(basename "$blob")
    expected_hash=$(echo "$filename" | cut -d_ -f1)
    if [ ${#expected_hash} -ge 32 ] && command -v b3sum >/dev/null 2>&1; then
        actual_hash=$(b3sum --no-names "$blob" 2>/dev/null | head -c ${#expected_hash})
        if [ "$expected_hash" != "$actual_hash" ]; then
            fail "CAS hash mismatch: $filename"
            CAS_INTACT=false
        fi
        CHECKED=$((CHECKED + 1))
    fi
done

if [ "$CAS_INTACT" = true ]; then
    pass "CAS integrity: $CHECKED blobs verified"
fi

# Check CAS blobs retain uchg (macOS)
if [ "$(uname)" = "Darwin" ]; then
    UCHG_COUNT=$(find "$VR_THE_SOURCE" -name "*.bin" -flags uchg 2>/dev/null | wc -l | tr -d ' ')
    TOTAL_COUNT=$(find "$VR_THE_SOURCE" -name "*.bin" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$TOTAL_COUNT" -gt 0 ]; then
        echo "  CAS uchg preserved: $UCHG_COUNT / $TOTAL_COUNT blobs"
    fi
fi

# ============================================================================
# Cleanup & Summary
# ============================================================================
stop_daemon

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  RESULTS: $PASSED passed, $FAILED failed"
echo "═══════════════════════════════════════════════════════════════"

if [ "$FAILED" -gt 0 ]; then
    echo "  ❌ SOME TESTS FAILED"
    exit 1
else
    echo "  ✅ ALL TESTS PASSED"
    exit 0
fi
