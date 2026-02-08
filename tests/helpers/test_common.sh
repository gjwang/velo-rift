#!/bin/bash
# ============================================================================
# Shared Test Helpers for VRift POC/QA Tests
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/../helpers/test_common.sh"
# ============================================================================

# Colors
export T_GREEN='\033[0;32m'
export T_RED='\033[0;31m'
export T_YELLOW='\033[0;33m'
export T_CYAN='\033[0;36m'
export T_NC='\033[0m'

# Project paths (auto-detect)
export T_PROJECT_ROOT="${T_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export T_VRIFT_BIN="${T_PROJECT_ROOT}/target/release/vrift"
export T_VRIFTD_BIN="${T_PROJECT_ROOT}/target/release/vriftd"
export T_SHIM_LIB="${T_PROJECT_ROOT}/target/release/libvrift_inception_layer.dylib"

# safe_rm: Remove directory/file handling macOS immutable (uchg) CAS flags
# Usage: safe_rm /path/to/dir
safe_rm() {
    local target="$1"
    if [ -e "$target" ]; then
        if [ "$(uname -s)" = "Darwin" ]; then
            chflags -R nouchg "$target" 2>/dev/null || true
        fi
        rm -rf "$target" 2>/dev/null || true
    fi
}

# setup_work_dir: Create isolated temp working directory
# Usage: WORK_DIR=$(setup_work_dir)
setup_work_dir() {
    local dir
    dir=$(mktemp -d)
    echo "$dir"
}

# register_cleanup: Set EXIT trap to safe_rm the given directory
# Usage: register_cleanup "$WORK_DIR"
register_cleanup() {
    local dir="$1"
    # shellcheck disable=SC2064
    trap "safe_rm '$dir'" EXIT
}

# kill_daemon: Stop any running vriftd/vdird processes
kill_daemon() {
    pkill -9 vriftd 2>/dev/null || true
    pkill -9 vrift-vdird 2>/dev/null || true
    sleep 1
}
