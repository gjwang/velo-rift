#!/bin/bash
# ==============================================================================
# Test: Symlink Creation No-Recursion Guard
# ==============================================================================
# After IT_SYMLINK was moved to __DATA,__interpose, symlink_inception must NOT
# call libc::symlink (which would recurse back into itself). This test verifies
# that symlink creation completes within a reasonable time (no infinite recursion)
# and returns expected results.
#
# Test cases:
#   SYM-NR.1: Create symlink to regular file (non-VFS) — must succeed
#   SYM-NR.2: Create symlink inside VFS territory — must be blocked (EPERM/EEXIST)
#   SYM-NR.3: Create symlink with timeout guard (3s) — no hang detection
#   SYM-NR.4: Create multiple symlinks rapidly — stress test for recursion
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
TOTAL=0

pass() { ((PASS++)); ((TOTAL++)); echo "  ✅ PASS: $1"; }
fail() { ((FAIL++)); ((TOTAL++)); echo "  ❌ FAIL: $1"; }

# Portable timeout: use `timeout` if available, else perl alarm fallback
# Returns 124 on timeout (same as GNU timeout)
run_timeout() {
    local secs="$1"; shift
    if command -v timeout &>/dev/null; then
        timeout "$secs" "$@"
    else
        perl -e '
            alarm(shift @ARGV);
            $SIG{ALRM} = sub { exit 124 };
            exec @ARGV or die "exec: $!";
        ' "$secs" "$@"
    fi
}

# Setup
WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT
REAL_FILE="$WORKDIR/real_file.txt"
echo "hello" > "$REAL_FILE"

echo "=== SYM-NR: Symlink No-Recursion Test ==="

# SYM-NR.1: Basic symlink creation (non-VFS, should work)
echo "[SYM-NR.1] Basic symlink creation"
LINK_PATH="$WORKDIR/link1"
if run_timeout 3 ln -s "$REAL_FILE" "$LINK_PATH" 2>/dev/null; then
    if [ -L "$LINK_PATH" ] && [ "$(readlink "$LINK_PATH")" = "$REAL_FILE" ]; then
        pass "SYM-NR.1: symlink created and target resolved"
    else
        fail "SYM-NR.1: symlink created but target wrong"
    fi
else
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 124 ]; then
        fail "SYM-NR.1: TIMEOUT — infinite recursion detected!"
    else
        fail "SYM-NR.1: symlink creation failed (exit=$EXIT_CODE)"
    fi
fi

# SYM-NR.2: VFS territory symlink (if VFS active)
echo "[SYM-NR.2] VFS territory symlink block"
VFS_PREFIX="${VRIFT_VFS_PREFIX:-}"
if [ -n "$VFS_PREFIX" ] && [ -d "$VFS_PREFIX" ]; then
    VFS_LINK="$VFS_PREFIX/.test_symlink_nr2_$$"
    if run_timeout 3 ln -s "$REAL_FILE" "$VFS_LINK" 2>/dev/null; then
        fail "SYM-NR.2: VFS symlink creation should be blocked (was allowed)"
        rm -f "$VFS_LINK" 2>/dev/null
    else
        pass "SYM-NR.2: VFS symlink correctly blocked"
    fi
else
    pass "SYM-NR.2: [SKIP] No VFS active — skipped"
fi

# SYM-NR.3: Timeout guard — create symlink with strict 3-second timeout
echo "[SYM-NR.3] Timeout guard (3s)"
LINK_PATH2="$WORKDIR/link_timeout"
START_TIME=$(date +%s)
if run_timeout 3 /bin/ln -s "$REAL_FILE" "$LINK_PATH2" 2>/dev/null; then
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    if [ $ELAPSED -lt 3 ]; then
        pass "SYM-NR.3: completed in ${ELAPSED}s (no hang)"
    else
        fail "SYM-NR.3: took ${ELAPSED}s — suspiciously slow"
    fi
else
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 124 ]; then
        fail "SYM-NR.3: CRITICAL — infinite recursion hang detected!"
    else
        fail "SYM-NR.3: symlink failed (exit=$EXIT_CODE)"
    fi
fi

# SYM-NR.4: Rapid symlink creation stress test
echo "[SYM-NR.4] Rapid symlink stress (100 symlinks)"
STRESS_DIR="$WORKDIR/stress"
mkdir -p "$STRESS_DIR"
STRESS_OK=true
if run_timeout 5 bash -c '
    i=1; while [ $i -le 100 ]; do
        ln -s "'"$REAL_FILE"'" "'"$STRESS_DIR"'/link_$i" 2>/dev/null || exit 1
        i=$((i+1))
    done
' 2>/dev/null; then
    CREATED=$(ls "$STRESS_DIR" | wc -l | tr -d ' ')
    if [ "$CREATED" -eq 100 ]; then
        pass "SYM-NR.4: 100 symlinks created without hang"
    else
        fail "SYM-NR.4: only $CREATED/100 symlinks created"
    fi
else
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 124 ]; then
        fail "SYM-NR.4: CRITICAL — hang during stress test!"
    else
        fail "SYM-NR.4: stress test failed (exit=$EXIT_CODE)"
    fi
fi

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
[ $FAIL -eq 0 ] && exit 0 || exit 1
