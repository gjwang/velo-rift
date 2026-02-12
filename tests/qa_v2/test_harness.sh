#!/usr/bin/env bash
# test_harness.sh — Common test utilities for Velo Rift QA test scripts
#
# Usage: Source this file at the top of any test script:
#   source "$(dirname "$0")/test_harness.sh"
#
# Provides:
#   - portable_timeout N cmd...  — cross-platform timeout
#   - ensure_daemon_stopped      — kill any running vriftd
#   - start_daemon_and_wait [secs] — start daemon + poll readiness
#   - cleanup_cas_dir dir        — chflags nouchg + rm -rf
#   - require_release_build      — verify release binaries exist

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source SSOT env vars (REPO_ROOT, VRIFT_CLI, VRIFTD, VRIFT_SOCKET_PATH, etc.)
source "$SCRIPT_DIR/../lib/vrift_env.sh"

PROJECT_ROOT="$REPO_ROOT"
VRIFT_BIN="$VRIFT_CLI"
VRIFTD_BIN="$VRIFTD"

# ──────────────────────────────────────────────
# Portable timeout (macOS has no GNU timeout)
# ──────────────────────────────────────────────
portable_timeout() {
    local secs=$1; shift
    if command -v timeout &>/dev/null; then
        timeout "$secs" "$@"
    else
        perl -e "alarm $secs; exec @ARGV" "$@"
    fi
}

# ──────────────────────────────────────────────
# Daemon management
# ──────────────────────────────────────────────
ensure_daemon_stopped() {
    pkill -f vriftd 2>/dev/null || true
    sleep 0.3
    # Remove stale socket (uses SSOT path from vrift_env.sh)
    rm -f "$VRIFT_SOCKET_PATH" 2>/dev/null || true
}

start_daemon_and_wait() {
    local max_wait=${1:-10}
    local cas_root="${VR_THE_SOURCE:-}"

    ensure_daemon_stopped

    (
        unset DYLD_INSERT_LIBRARIES
        unset DYLD_FORCE_FLAT_NAMESPACE
        "$VRIFTD_BIN" start &
    )
    disown 2>/dev/null || true

    # Poll until daemon is ready
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if portable_timeout 3 "$VRIFT_BIN" daemon status 2>/dev/null | grep -q "running\|Operational"; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    echo "⚠️  Warning: daemon did not become ready within ${max_wait}s"
    return 1
}

# ──────────────────────────────────────────────
# CAS cleanup (handles immutable files on macOS)
# ──────────────────────────────────────────────
cleanup_cas_dir() {
    local dir="$1"
    if [ -z "$dir" ] || [ "$dir" = "/" ]; then
        echo "ERROR: cleanup_cas_dir called with empty or root path"
        return 1
    fi
    if [ "$(uname -s)" = "Darwin" ]; then
        chflags -R nouchg "$dir" 2>/dev/null || true
    fi
    rm -rf "$dir"
}

# ──────────────────────────────────────────────
# Build verification
# ──────────────────────────────────────────────
require_release_build() {
    if [ ! -f "$VRIFT_BIN" ] || [ ! -f "$VRIFTD_BIN" ]; then
        echo "❌ Release binaries not found. Run: cargo build --release -p vrift-cli -p vrift-daemon"
        exit 1
    fi
}
