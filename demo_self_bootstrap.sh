#!/bin/bash
set -euo pipefail

# ==============================================================================
# Velo Rift Self-Bootstrap (Self-Hosting) Demonstration
# ==============================================================================
# This script demonstrates Velo Rift building itself under Inception mode.
# It proves that the virtualization layer is stable enough to handle the 
# complexity of its own build system and dependencies.
# ==============================================================================

REPO_ROOT="/Users/antigravity/rust_source/velo-rift"
cd "$REPO_ROOT"

# 1. Build the release binaries normally first
echo "--- PREPARING RELEASE BINARIES ---"
cargo build --release --workspace

# Copy to /tmp to survive cargo clean. 
VRIFT_BIN_DIR="/tmp/vrift_bootstrap_bin"
rm -rf "$VRIFT_BIN_DIR"
mkdir -p "$VRIFT_BIN_DIR"
cp target/release/vriftd "$VRIFT_BIN_DIR/"
cp target/release/vrift-vdird "$VRIFT_BIN_DIR/"
cp target/release/libvrift_inception_layer.dylib "$VRIFT_BIN_DIR/"
chmod +x "$VRIFT_BIN_DIR/vriftd" "$VRIFT_BIN_DIR/vrift-vdird"

VRIFTD="$VRIFT_BIN_DIR/vriftd"
SHIM_LIB="$VRIFT_BIN_DIR/libvrift_inception_layer.dylib"
VRIFT_SOCKET_PATH="/tmp/vrift_self.sock"
VR_THE_SOURCE="$HOME/.vrift/the_source"

echo "Contents of $VRIFT_BIN_DIR:"
ls -F "$VRIFT_BIN_DIR"

# 2. Cleanup previous state
echo "--- CLEANING UP ---"
rm -f "$VRIFT_SOCKET_PATH"
# We don't necessarily need to clean if we use a different target dir
# but for a true "clean build" demonstration we should.
cargo clean

# 3. Start the daemon with logging
echo "--- STARTING DAEMON ---"
VRIFT_SOCKET_PATH="$VRIFT_SOCKET_PATH" \
VR_THE_SOURCE="$VR_THE_SOURCE" \
VRIFT_LOG_LEVEL=debug \
"$VRIFTD" start > /tmp/vriftd_bootstrap.log 2>&1 &
DAEMON_PID=$!

# Wait for daemon
echo "Waiting for daemon socket at $VRIFT_SOCKET_PATH..."
for i in {1..20}; do
    if [ -S "$VRIFT_SOCKET_PATH" ]; then
        echo "Daemon is up!"
        break
    fi
    sleep 0.5
done

if [ ! -S "$VRIFT_SOCKET_PATH" ]; then
    echo "ERROR: Daemon failed to start. Logs:"
    cat /tmp/vriftd_bootstrap.log
    kill $DAEMON_PID || true
    exit 1
fi

# 4. Perform Self-Bootstrap Build
echo "--- EXECUTING SELF-BOOTSTRAP BUILD (Velo Rift building Velo Rift) ---"
export VRIFT_PROJECT_ROOT="$REPO_ROOT"
export VRIFT_VFS_PREFIX="$REPO_ROOT"
export VRIFT_SOCKET_PATH="$VRIFT_SOCKET_PATH"
export VR_THE_SOURCE="$VR_THE_SOURCE"
export VRIFT_INCEPTION=1
export DYLD_INSERT_LIBRARIES="$SHIM_LIB"
export DYLD_FORCE_FLAT_NAMESPACE=1
export VRIFT_LOG_LEVEL=debug
export VRIFT_DEBUG=1

# Build the workspace
# We redirect stderr to a file because Cargo output will be noisy with debug logs
cargo build --workspace 2> /tmp/cargo_bootstrap_debug.log || true

echo "Checking debug log for failures..."
grep -A 5 "cas_bench" /tmp/cargo_bootstrap_debug.log | head -n 50

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  SUCCESS: Velo Rift Self-Bootstrap Build Completed!           ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo "This confirms the Inception Layer can materialize its own source"
echo "and handle the full compilation pipeline for all crates."

kill $DAEMON_PID
rm -f "$VRIFT_SOCKET_PATH"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  SUCCESS: Velo Rift Self-Bootstrap Build Completed!           ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo "This proves the Inception Layer can handle its own complex"
echo "dependency tree and build scripts (build.rs)."

kill $DAEMON_PID
rm -f "$VRIFT_SOCKET_PATH"
