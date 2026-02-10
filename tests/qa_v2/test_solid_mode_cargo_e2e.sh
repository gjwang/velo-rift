#!/bin/bash
# ==============================================================================
# Solid Mode: Cargo Build E2E (User Perspective)
# ==============================================================================
# Tests the full user workflow:
#   1. Create a Rust project
#   2. Ingest → CAS + VDir
#   3. Enter inception mode
#   4. cargo build (initial)
#   5. touch src/lib.rs → cargo build (incremental)
#   6. touch src/lib.rs → cargo build (incremental again)
#   7. cargo clean → cargo build (rebuild from CAS)
#   8. Exit inception → cargo build (files should be physically intact)
#
# All steps must succeed — this is what a normal user experiences.
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
SKIPPED=0

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

skip() {
    echo "  ⏭️  SKIP: $1"
    SKIPPED=$((SKIPPED + 1))
}

run_inception() {
    # Run a command under inception (DYLD_INSERT_LIBRARIES + env vars)
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

run_inception_with_vdir() {
    # Run under inception with VDir mmap
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
echo "║  Solid Mode: Cargo Build E2E Test"
echo "╚══════════════════════════════════════════════════════════════════════╝"

if ! check_prerequisites; then
    echo "❌ Prerequisites not met. Build first: cargo build"
    exit 1
fi

echo "  Shim:      $SHIM_LIB"
echo "  Daemon:    $VRIFTD_BIN"
echo "  CLI:       $VRIFT_CLI"
echo ""

# ============================================================================
# Phase 0: Setup — Create a real Rust project
# ============================================================================
echo "═══ Phase 0: Setup ═══"

setup_test_workspace

cd "$TEST_WORKSPACE"

# Create a minimal but realistic Rust project
cat > Cargo.toml << 'CARGO_TOML'
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
CARGO_TOML

mkdir -p src

cat > src/lib.rs << 'LIB_RS'
/// A simple greeting function
pub fn greet(name: &str) -> String {
    format!("Hello, {}! Welcome to Velo Rift.", name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_greet() {
        assert_eq!(greet("World"), "Hello, World! Welcome to Velo Rift.");
    }
}
LIB_RS

cat > src/main.rs << 'MAIN_RS'
fn main() {
    println!("{}", hello_vrift::greet("World"));
}
MAIN_RS

echo "  ✓ Created Rust project at $TEST_WORKSPACE"

# ============================================================================
# Phase 1: Baseline — cargo build without inception
# ============================================================================
echo ""
echo "═══ Phase 1: Baseline build (no inception) ═══"

if cargo build 2>&1; then
    pass "Baseline cargo build"
else
    fail "Baseline cargo build"
    echo "  Cannot proceed without baseline build"
    exit 1
fi

# Verify binary works
if ./target/debug/hello-vrift 2>&1 | grep -q "Hello, World!"; then
    pass "Binary runs correctly"
else
    fail "Binary output mismatch"
fi

# ============================================================================
# Phase 2: Ingest — CAS + VDir
# ============================================================================
echo ""
echo "═══ Phase 2: Ingest into CAS ═══"

# Start daemon
start_daemon "warn"

# Wait for daemon to stabilize
sleep 1

# Ingest the project (current directory)
if VRIFT_SOCKET_PATH="$VRIFT_SOCKET_PATH" VR_THE_SOURCE="$VR_THE_SOURCE" \
   "$VRIFT_CLI" ingest --parallel . 2>&1; then
    pass "Ingest completed"
else
    fail "Ingest failed"
    echo "  Cannot proceed without ingest"
    exit 1
fi

# Wait for VDir generation
sleep 2

# Find VDir mmap
VDIR_MMAP_PATH=""
if [ -d "$TEST_WORKSPACE/.vrift/vdir" ]; then
    VDIR_MMAP_PATH=$(find "$TEST_WORKSPACE/.vrift/vdir" -name "*.vdir" 2>/dev/null | head -1)
fi

# Try global vdir location if project-local not found
if [ -z "$VDIR_MMAP_PATH" ]; then
    VDIR_MMAP_PATH=$(find "${HOME}/.vrift/vdir" -name "*.vdir" -newer "$TEST_WORKSPACE/Cargo.toml" 2>/dev/null | head -1)
fi

if [ -n "$VDIR_MMAP_PATH" ]; then
    pass "VDir mmap found: $(basename "$VDIR_MMAP_PATH")"
else
    skip "VDir mmap not found — will test without VDir acceleration"
fi

echo "  CAS files: $(find "$VR_THE_SOURCE" -name "*.bin" 2>/dev/null | wc -l | tr -d ' ')"

# ============================================================================
# Phase 3: Inception — Initial cargo build
# ============================================================================
echo ""
echo "═══ Phase 3: Inception cargo build (initial) ═══"

if [ -n "$VDIR_MMAP_PATH" ]; then
    BUILD_CMD="run_inception_with_vdir"
else
    BUILD_CMD="run_inception"
fi

if $BUILD_CMD cargo build 2>&1; then
    pass "Inception cargo build (initial)"
else
    fail "Inception cargo build (initial)"
fi

# Verify binary works under inception
if $BUILD_CMD ./target/debug/hello-vrift 2>&1 | grep -q "Hello, World!"; then
    pass "Binary works under inception"
else
    fail "Binary output mismatch under inception"
fi

# ============================================================================
# Phase 4: Incremental — touch source → rebuild
# ============================================================================
echo ""
echo "═══ Phase 4: Incremental build (touch → build) ═══"

sleep 1  # Ensure mtime changes
touch src/lib.rs
echo "  Touched src/lib.rs"

if $BUILD_CMD cargo build 2>&1; then
    pass "Incremental build after touch"
else
    fail "Incremental build after touch"
fi

# Verify binary still works
if $BUILD_CMD ./target/debug/hello-vrift 2>&1 | grep -q "Hello, World!"; then
    pass "Binary still correct after incremental"
else
    fail "Binary output wrong after incremental"
fi

# ============================================================================
# Phase 5: Second incremental — confirm stability
# ============================================================================
echo ""
echo "═══ Phase 5: Second incremental build ═══"

sleep 1
touch src/main.rs
echo "  Touched src/main.rs"

if $BUILD_CMD cargo build 2>&1; then
    pass "Second incremental build"
else
    fail "Second incremental build"
fi

if $BUILD_CMD ./target/debug/hello-vrift 2>&1 | grep -q "Hello, World!"; then
    pass "Binary correct after second incremental"
else
    fail "Binary wrong after second incremental"
fi

# ============================================================================
# Phase 6: Clean → Rebuild (materialize from CAS)
# ============================================================================
echo ""
echo "═══ Phase 6: Clean → Rebuild from CAS ═══"

# Clean target (remove all build artifacts)
# Need to handle uchg flags from materialization
chflags -R nouchg "$TEST_WORKSPACE/target" 2>/dev/null || true
rm -rf "$TEST_WORKSPACE/target"
echo "  Removed target/ directory"

if [ ! -d "$TEST_WORKSPACE/target" ]; then
    pass "target/ removed successfully"
else
    fail "target/ still exists after rm -rf"
fi

# Rebuild — this tests stat-time materialization
if $BUILD_CMD cargo build 2>&1; then
    pass "Clean rebuild under inception"
else
    fail "Clean rebuild under inception"
fi

# Verify binary works after clean rebuild
if $BUILD_CMD ./target/debug/hello-vrift 2>&1 | grep -q "Hello, World!"; then
    pass "Binary correct after clean rebuild"
else
    fail "Binary wrong after clean rebuild"
fi

# ============================================================================
# Phase 7: Exit inception → build still works
# ============================================================================
echo ""
echo "═══ Phase 7: Post-inception build (no shim) ═══"

# Build WITHOUT inception (plain cargo build)
# This tests that materialized files are real physical files
if cargo build 2>&1; then
    pass "Post-inception cargo build (no shim)"
else
    fail "Post-inception cargo build (no shim)"
fi

if ./target/debug/hello-vrift 2>&1 | grep -q "Hello, World!"; then
    pass "Binary works without inception"
else
    fail "Binary output wrong without inception"
fi

# ============================================================================
# Phase 8: CAS integrity check
# ============================================================================
echo ""
echo "═══ Phase 8: CAS integrity ═══"

# Verify CAS blobs still have correct hash == filename
CAS_INTACT=true
for blob in $(find "$VR_THE_SOURCE" -name "*.bin" 2>/dev/null | head -10); do
    # Extract expected hash from path (blake3/xx/yy/HASH_SIZE.bin)
    filename=$(basename "$blob")
    expected_hash=$(echo "$filename" | cut -d_ -f1)
    if [ ${#expected_hash} -ge 32 ]; then
        # Compute actual hash
        if command -v b3sum >/dev/null 2>&1; then
            actual_hash=$(b3sum --no-names "$blob" 2>/dev/null | head -c ${#expected_hash})
            if [ "$expected_hash" != "$actual_hash" ]; then
                echo "  ⚠️  CAS hash mismatch: $filename"
                echo "     Expected: $expected_hash"
                echo "     Actual:   $actual_hash"
                CAS_INTACT=false
            fi
        fi
    fi
done

if [ "$CAS_INTACT" = true ]; then
    pass "CAS integrity preserved"
else
    fail "CAS integrity compromised!"
fi

# Check CAS blobs still have uchg flag (macOS)
if [ "$(uname)" = "Darwin" ]; then
    UCHG_COUNT=$(find "$VR_THE_SOURCE" -name "*.bin" -flags uchg 2>/dev/null | head -10 | wc -l | tr -d ' ')
    TOTAL_COUNT=$(find "$VR_THE_SOURCE" -name "*.bin" 2>/dev/null | head -10 | wc -l | tr -d ' ')
    if [ "$TOTAL_COUNT" -gt 0 ]; then
        echo "  CAS blobs with uchg: $UCHG_COUNT / $TOTAL_COUNT"
    fi
fi

# ============================================================================
# Cleanup & Summary
# ============================================================================
stop_daemon

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  RESULTS: $PASSED passed, $FAILED failed, $SKIPPED skipped"
echo "═══════════════════════════════════════════════════════════════"

if [ "$FAILED" -gt 0 ]; then
    echo "  ❌ SOME TESTS FAILED"
    exit 1
else
    echo "  ✅ ALL TESTS PASSED"
    exit 0
fi
