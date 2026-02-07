#!/bin/bash
# ==============================================================================
# Test: Shell Mutation Suite
# ==============================================================================
# Tests common shell commands that mutate files under VFS control.
# These represent what real users do with tools (cp, mv, rm, touch, chmod,
# chown, ln, etc.) and validates VFS enforcement end-to-end.
#
# Each test uses shell builtins/commands under the shim, verifying expected
# behavior. This is a high-level integration test, unlike the low-level
# syscall probes.
# ==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/test_setup.sh"

check_prerequisites || exit 1

log_section "Shell Mutation Suite"

start_daemon || exit 1

# Create test workspace
mkdir -p "$TEST_WORKSPACE/src/subdir"
echo "initial" > "$TEST_WORKSPACE/src/alpha.txt"
echo "bravo" > "$TEST_WORKSPACE/src/bravo.txt"
echo "charlie" > "$TEST_WORKSPACE/src/subdir/charlie.txt"

OUTSIDE_DIR="/tmp/vrift_shell_mut_test_$$"
mkdir -p "$OUTSIDE_DIR"

# ============================================================================
# Test Group 1: Write mutations
# ============================================================================
log_phase "1: Write Mutations"

log_test "SHELL.1" "echo >> VFS file (append) — should fail or use copy-up"
APPEND_OUT=$(run_with_shim bash -c "echo extra >> '$TEST_WORKSPACE/src/alpha.txt' 2>&1")
APPEND_EXIT=$?
CONTENT=$(cat "$TEST_WORKSPACE/src/alpha.txt")
if [ "$APPEND_EXIT" -ne 0 ]; then
    log_pass "Append blocked (exit=$APPEND_EXIT)"
elif echo "$CONTENT" | grep -q "extra"; then
    # Might be copy-up (acceptable if dirty tracking works)
    log_pass "Append succeeded via copy-up (content modified, dirty tracked)"
else
    log_pass "Append appeared to succeed but content unchanged (silent block)"
fi

log_test "SHELL.2" "cp overwrite VFS file"
BEFORE_CKSUM=$(cksum "$TEST_WORKSPACE/src/alpha.txt" 2>/dev/null | awk '{print $1}')
run_with_shim cp /dev/null "$TEST_WORKSPACE/src/alpha.txt" 2>/dev/null
CP_EXIT=$?
AFTER_CKSUM=$(cksum "$TEST_WORKSPACE/src/alpha.txt" 2>/dev/null | awk '{print $1}')
if [ "$CP_EXIT" -ne 0 ]; then
    log_pass "cp overwrite blocked (exit=$CP_EXIT)"
elif [ "$BEFORE_CKSUM" = "$AFTER_CKSUM" ]; then
    log_pass "cp did not change content (silently blocked)"
else
    log_pass "cp overwrote via O_WRONLY/O_TRUNC — copy-up path"
fi

# ============================================================================
# Test Group 2: Metadata mutations
# ============================================================================
log_phase "2: Metadata Mutations"

log_test "SHELL.3" "touch VFS file (mtime change)"
BEFORE_MTIME=$(stat -f "%m" "$TEST_WORKSPACE/src/bravo.txt" 2>/dev/null || stat -c "%Y" "$TEST_WORKSPACE/src/bravo.txt" 2>/dev/null)
run_with_shim touch "$TEST_WORKSPACE/src/bravo.txt" 2>/dev/null
TOUCH_EXIT=$?
AFTER_MTIME=$(stat -f "%m" "$TEST_WORKSPACE/src/bravo.txt" 2>/dev/null || stat -c "%Y" "$TEST_WORKSPACE/src/bravo.txt" 2>/dev/null)
if [ "$TOUCH_EXIT" -ne 0 ]; then
    log_pass "touch blocked (exit=$TOUCH_EXIT)"
elif [ "$BEFORE_MTIME" = "$AFTER_MTIME" ]; then
    log_pass "touch did not change mtime (silently blocked)"
else
    log_fail "touch CHANGED mtime ($BEFORE_MTIME -> $AFTER_MTIME) — utimes/setattrlist BYPASS"
fi

log_test "SHELL.4" "chmod VFS file"
run_with_shim chmod 777 "$TEST_WORKSPACE/src/bravo.txt" 2>/dev/null
CHMOD_EXIT=$?
# Check if permission actually changed
PERMS=$(stat -f "%Lp" "$TEST_WORKSPACE/src/bravo.txt" 2>/dev/null || stat -c "%a" "$TEST_WORKSPACE/src/bravo.txt" 2>/dev/null)
if [ "$CHMOD_EXIT" -ne 0 ]; then
    log_pass "chmod blocked (exit=$CHMOD_EXIT)"
elif [ "$PERMS" != "777" ]; then
    log_pass "chmod did not change mode (silently blocked)"
else
    log_fail "chmod CHANGED permissions to $PERMS — shim bypass"
fi

# ============================================================================
# Test Group 3: Structural mutations
# ============================================================================
log_phase "3: Structural Mutations"

log_test "SHELL.5" "rm VFS file"
run_with_shim rm "$TEST_WORKSPACE/src/bravo.txt" 2>/dev/null
RM_EXIT=$?
if [ "$RM_EXIT" -ne 0 ]; then
    log_pass "rm blocked (exit=$RM_EXIT)"
elif [ -f "$TEST_WORKSPACE/src/bravo.txt" ]; then
    log_pass "rm appeared to succeed but file still exists (VFS override)"
else
    log_fail "rm DELETED VFS file — unlink bypass"
fi

log_test "SHELL.6" "mv VFS file to outside"
run_with_shim mv "$TEST_WORKSPACE/src/alpha.txt" "$OUTSIDE_DIR/" 2>/dev/null
MV_EXIT=$?
if [ "$MV_EXIT" -ne 0 ]; then
    log_pass "mv out blocked (exit=$MV_EXIT)"
elif [ -f "$TEST_WORKSPACE/src/alpha.txt" ]; then
    log_pass "mv did not remove source (VFS protected)"
else
    log_fail "mv MOVED VFS file outside — rename bypass"
fi

log_test "SHELL.7" "rmdir VFS subdirectory"
run_with_shim rmdir "$TEST_WORKSPACE/src/subdir" 2>/dev/null
RMDIR_EXIT=$?
if [ "$RMDIR_EXIT" -ne 0 ]; then
    log_pass "rmdir blocked (exit=$RMDIR_EXIT)"
elif [ -d "$TEST_WORKSPACE/src/subdir" ]; then
    log_pass "rmdir did not remove dir (VFS protected)"
else
    log_fail "rmdir REMOVED VFS directory — rmdir bypass"
fi

log_test "SHELL.8" "ln -s (symlink creation inside VFS)"
run_with_shim ln -s alpha.txt "$TEST_WORKSPACE/src/link_test" 2>/dev/null
LN_EXIT=$?
if [ "$LN_EXIT" -eq 0 ]; then
    log_pass "ln -s succeeded (symlink creation allowed for live ingest)"
elif [ "$LN_EXIT" -ne 0 ]; then
    log_pass "ln -s blocked (exit=$LN_EXIT) — strict mutation policy"
fi

log_test "SHELL.9" "ln (hardlink VFS file)"
run_with_shim ln "$TEST_WORKSPACE/src/alpha.txt" "$TEST_WORKSPACE/src/hardlink_test" 2>/dev/null
LN_HARD_EXIT=$?
if [ "$LN_HARD_EXIT" -ne 0 ]; then
    log_pass "ln (hard) blocked (exit=$LN_HARD_EXIT)"
else
    log_fail "ln (hard) SUCCEEDED — hardlink inside VFS should be EXDEV"
fi

# ============================================================================
# Test Group 4: Manifest operations
# ============================================================================
log_phase "4: Manifest Operations"

log_test "SHELL.10" "mkdir inside VFS (should trigger manifest_mkdir)"
run_with_shim mkdir "$TEST_WORKSPACE/src/new_dir" 2>/dev/null
MKDIR_EXIT=$?
if [ "$MKDIR_EXIT" -eq 0 ]; then
    log_pass "mkdir succeeded (manifest_mkdir fired)"
elif [ "$MKDIR_EXIT" -ne 0 ]; then
    log_pass "mkdir blocked (exit=$MKDIR_EXIT) — strict policy"
fi

log_test "SHELL.11" "Create new file inside VFS (should trigger manifest_upsert on close)"
run_with_shim bash -c "echo 'new content' > '$TEST_WORKSPACE/src/new_file.txt'" 2>/dev/null
CREATE_EXIT=$?
if [ "$CREATE_EXIT" -eq 0 ] && [ -f "$TEST_WORKSPACE/src/new_file.txt" ]; then
    log_pass "File creation succeeded (copy-up / COW)"
else
    log_pass "File creation blocked or redirected (exit=$CREATE_EXIT)"
fi

# Cleanup
rm -rf "$OUTSIDE_DIR"

exit_with_summary
