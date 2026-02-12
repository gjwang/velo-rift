#!/bin/bash
# =============================================================================
# vrift_env.sh — SSOT bridge for shell scripts
# =============================================================================
#
# Source this file from any test/bench script to get canonical VRift env vars.
# This is the shell-side equivalent of vrift-config — a single place that
# defines default paths so scripts never hardcode them.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/../lib/vrift_env.sh"   # adjust path as needed
#
# After sourcing, these variables are exported:
#   REPO_ROOT           — velo-rift repo root
#   VRIFT_CLI           — path to release vrift binary
#   VRIFTD              — path to release vriftd binary
#   SHIM_LIB            — path to inception layer dylib/so
#   VRIFT_SOCKET_PATH   — daemon socket (from env → config → platform default)
#   VR_THE_SOURCE       — CAS root directory
# =============================================================================

# Repo root: auto-detect from this file's location (tests/lib/vrift_env.sh)
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
export REPO_ROOT

# Binary paths
VRIFT_CLI="${VRIFT_CLI:-$REPO_ROOT/target/release/vrift}"
VRIFTD="${VRIFTD:-$REPO_ROOT/target/release/vriftd}"
if [ "$(uname -s)" = "Darwin" ]; then
    SHIM_LIB="${SHIM_LIB:-$REPO_ROOT/target/release/libvrift_inception_layer.dylib}"
else
    SHIM_LIB="${SHIM_LIB:-$REPO_ROOT/target/release/libvrift_inception_layer.so}"
fi
export VRIFT_CLI VRIFTD SHIM_LIB

# ---------------------------------------------------------------------------
# Socket path resolution (mirrors vrift-config precedence):
#   1. VRIFT_SOCKET_PATH env var (already set by caller)
#   2. `vrift config get daemon.socket` (reads config.toml)
#   3. Platform default: /tmp/vrift.sock (macOS), /run/vrift/daemon.sock (Linux)
# ---------------------------------------------------------------------------
if [ -z "${VRIFT_SOCKET_PATH:-}" ]; then
    if [ -x "$VRIFT_CLI" ]; then
        _cfg_socket=$("$VRIFT_CLI" config get daemon.socket 2>/dev/null || true)
        [ -n "$_cfg_socket" ] && VRIFT_SOCKET_PATH="$_cfg_socket"
        unset _cfg_socket
    fi
    if [ -z "${VRIFT_SOCKET_PATH:-}" ]; then
        if [ "$(uname -s)" = "Darwin" ]; then
            VRIFT_SOCKET_PATH="/tmp/vrift.sock"
        else
            VRIFT_SOCKET_PATH="/run/vrift/daemon.sock"
        fi
    fi
fi
export VRIFT_SOCKET_PATH

# CAS root
VR_THE_SOURCE="${VR_THE_SOURCE:-$HOME/.vrift/the_source}"
export VR_THE_SOURCE

# ---------------------------------------------------------------------------
# Helper functions available after sourcing
# ---------------------------------------------------------------------------

# Check if daemon is reachable on the current socket
vrift_daemon_running() {
    [ -S "$VRIFT_SOCKET_PATH" ]
}

# Wait for daemon socket to appear (with timeout)
vrift_wait_for_daemon() {
    local max_wait="${1:-10}"
    local waited=0
    while [ ! -S "$VRIFT_SOCKET_PATH" ] && [ $waited -lt "$max_wait" ]; do
        sleep 0.5
        waited=$((waited + 1))
    done
    [ -S "$VRIFT_SOCKET_PATH" ]
}
