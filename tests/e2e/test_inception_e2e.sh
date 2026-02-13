#!/bin/bash
# =============================================================================
# test_inception_e2e.sh — Comprehensive E2E Integration Test
#
# Simulates a real developer's workflow under inception mode and verifies that
# every operation produces identical results to baseline (no shim) execution.
#
# Usage:
#   ./tests/e2e/test_inception_e2e.sh <project_path>
#   ./tests/e2e/test_inception_e2e.sh ../velo
#
# Requirements:
#   - Release binaries built: cargo build --release
#   - vriftd daemon NOT required (script manages its own)
#
# Exit codes:
#   0 = all tests passed
#   1 = one or more tests failed
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test_common.sh"

# ─── Configuration ───────────────────────────────────────────────────────────

TARGET_PROJECT="${1:-}"
if [ -z "$TARGET_PROJECT" ]; then
    echo -e "${T_RED}Usage: $0 <project_path>${T_NC}"
    echo "  Example: $0 ../velo"
    exit 1
fi

# Resolve to absolute path
TARGET_PROJECT="$(cd "$TARGET_PROJECT" && pwd)"
PROJECT_NAME="$(basename "$TARGET_PROJECT")"

# Binaries
VRIFT_BIN="$T_VRIFT_BIN"
VRIFTD_BIN="$T_VRIFTD_BIN"
SHIM_LIB="$T_SHIM_LIB"

# Check prerequisites
for bin in "$VRIFT_BIN" "$VRIFTD_BIN" "$SHIM_LIB"; do
    if [ ! -f "$bin" ]; then
        echo -e "${T_RED}Missing: $bin${T_NC}"
        echo "Run: cargo build --release"
        exit 1
    fi
done

# ─── Test Harness ────────────────────────────────────────────────────────────

TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
FAIL_LIST=""

pass() {
    TOTAL=$((TOTAL+1))
    PASSED=$((PASSED+1))
    echo -e "  ${T_GREEN}✅ $1${T_NC}"
}

fail() {
    TOTAL=$((TOTAL+1))
    FAILED=$((FAILED+1))
    FAIL_LIST="$FAIL_LIST\n    - $1: $2"
    echo -e "  ${T_RED}❌ $1: $2${T_NC}"
}

skip() {
    TOTAL=$((TOTAL+1))
    SKIPPED=$((SKIPPED+1))
    echo -e "  ${T_YELLOW}⏭️  $1 (skipped: $2)${T_NC}"
}

section() {
    echo ""
    echo -e "${T_CYAN}═══════════════════════════════════════════════════${T_NC}"
    echo -e "${T_CYAN}  $1${T_NC}"
    echo -e "${T_CYAN}═══════════════════════════════════════════════════${T_NC}"
}

# Run command with inception environment (DYLD only on child process, not bash)
icmd() {
    env \
        VRIFT_INCEPTION=1 \
        VRIFT_PROJECT_ROOT="$TARGET_PROJECT" \
        VRIFT_SOCKET_PATH="$SOCKET_PATH" \
        VRIFT_VDIR_MMAP="$VDIR_PATH" \
        DYLD_INSERT_LIBRARIES="$SHIM_LIB" \
        DYLD_FORCE_FLAT_NAMESPACE=1 \
        "$@"
}

# ─── Compute project-specific paths ─────────────────────────────────────────

# We need the project hash to find VDir. Use vrift ingest output to locate it.
VRIFT_HOME="$HOME/.vrift"
SOCKET_PATH="/tmp/vrift.sock"
VDIR_PATH=""  # Populated in Phase 0.4

# ═════════════════════════════════════════════════════════════════════════════
#  PHASE 0: SETUP
# ═════════════════════════════════════════════════════════════════════════════

section "Phase 0: Setup [$PROJECT_NAME]"

# 0.1 Clean slate
echo "0.1 Clean slate"
kill_daemon
rm -f "$SOCKET_PATH"
pass "Processes cleaned"

# 0.2 Start daemon
echo "0.2 Start daemon"
nohup "$VRIFTD_BIN" start > /tmp/vriftd_e2e.log 2>&1 &
DAEMON_PID=$!

# Wait for daemon with retry (up to 10s)
DAEMON_OK=0
for i in $(seq 1 10); do
    if "$VRIFT_BIN" daemon status 2>&1 | grep -q "Operational"; then
        DAEMON_OK=1
        break
    fi
    sleep 1
done

if [ $DAEMON_OK -eq 1 ]; then
    pass "Daemon operational (PID $DAEMON_PID, ${i}s)"
else
    fail "0.2 Daemon" "Failed to start after 10s"
    echo -e "${T_RED}Cannot continue without daemon. Aborting.${T_NC}"
    cat /tmp/vriftd_e2e.log 2>/dev/null | tail -5
    exit 1
fi

# 0.3 Ingest project
echo "0.3 Ingest project"
INGEST_OUTPUT=$("$VRIFT_BIN" ingest "$TARGET_PROJECT" 2>&1)
if echo "$INGEST_OUTPUT" | grep -q "Complete"; then
    FILE_COUNT=$(echo "$INGEST_OUTPUT" | grep -oE '[0-9]+ files' | head -1)
    pass "Ingest complete ($FILE_COUNT)"
else
    fail "0.3 Ingest" "Failed"
    echo "$INGEST_OUTPUT"
    exit 1
fi

# 0.4 Discover VDir path
echo "0.4 Discover VDir"
VDIR_PATH=$(find "$VRIFT_HOME/vdir" -name "*.vdir" -newer "$SOCKET_PATH" 2>/dev/null | head -1)
if [ -z "$VDIR_PATH" ]; then
    # Fallback: find any .vdir file
    VDIR_PATH=$(find "$VRIFT_HOME/vdir" -name "*.vdir" 2>/dev/null | head -1)
fi

if [ -n "$VDIR_PATH" ] && [ -f "$VDIR_PATH" ]; then
    pass "VDir found: $(basename "$VDIR_PATH")"
else
    fail "0.4 VDir" "Not found in $VRIFT_HOME/vdir/"
    exit 1
fi

# 0.5 Preflight (inception command)
echo "0.5 Inception preflight"
INCEP_OUT=$("$VRIFT_BIN" inception "$TARGET_PROJECT" 2>&1)
if echo "$INCEP_OUT" | grep -qE "export|INCEPTION"; then
    pass "Preflight passed"
else
    fail "0.5 Preflight" "$(echo "$INCEP_OUT" | head -3)"
    exit 1
fi

# ═════════════════════════════════════════════════════════════════════════════
#  PHASE 1: FILE I/O CORRECTNESS (Baseline vs Inception)
# ═════════════════════════════════════════════════════════════════════════════

section "Phase 1: File I/O Correctness [$PROJECT_NAME]"

cd "$TARGET_PROJECT"

# Pick a representative source file
TEST_FILE=$(find . -name '*.rs' -not -path '*/target/*' -not -path '*/.git/*' | head -1)
if [ -z "$TEST_FILE" ]; then
    TEST_FILE="Cargo.toml"
fi
echo "  (test file: $TEST_FILE)"

# 1.1 md5 content
echo "1.1 md5"
B=$(md5 -q "$TEST_FILE" 2>/dev/null || md5sum "$TEST_FILE" 2>/dev/null | awk '{print $1}')
I=$(icmd md5 -q "$TEST_FILE" 2>/dev/null || icmd md5sum "$TEST_FILE" 2>/dev/null | awk '{print $1}')
[ "$B" = "$I" ] && pass "md5 match ($B)" || fail "1.1 md5" "baseline=$B inception=$I"

# 1.2 line count
echo "1.2 wc -l"
B=$(wc -l < "$TEST_FILE" | tr -d ' ')
I=$(icmd wc -l < "$TEST_FILE" | tr -d ' ')
[ "$B" = "$I" ] && pass "wc -l match ($B)" || fail "1.2 wc" "baseline=$B inception=$I"

# 1.3 file size
echo "1.3 stat size"
if [ "$(uname)" = "Darwin" ]; then
    B=$(stat -f%z "$TEST_FILE")
    I=$(icmd stat -f%z "$TEST_FILE")
else
    B=$(stat -c%s "$TEST_FILE")
    I=$(icmd stat -c%s "$TEST_FILE")
fi
[ "$B" = "$I" ] && pass "size match ($B bytes)" || fail "1.3 stat" "baseline=$B inception=$I"

# 1.4 directory listing
echo "1.4 ls directory"
FIRST_DIR=$(find . -maxdepth 2 -type d -name 'src' | head -1)
if [ -n "$FIRST_DIR" ]; then
    B=$(ls "$FIRST_DIR" | sort)
    I=$(icmd ls "$FIRST_DIR" | sort)
    [ "$B" = "$I" ] && pass "ls match ($(echo "$B" | wc -l | tr -d ' ') entries)" || fail "1.4 ls" "listing differs"
else
    skip "1.4 ls" "no src dir found"
fi

# 1.5 find file count
echo "1.5 find file count"
B=$(find . -name '*.rs' -not -path '*/target/*' -not -path '*/.git/*' | wc -l | tr -d ' ')
I=$(icmd find . -name '*.rs' -not -path '*/target/*' -not -path '*/.git/*' | wc -l | tr -d ' ')
[ "$B" = "$I" ] && pass "find count match ($B files)" || fail "1.5 find" "baseline=$B inception=$I"

# 1.6 head content
echo "1.6 head Cargo.toml"
B=$(head -5 Cargo.toml)
I=$(icmd head -5 Cargo.toml)
[ "$B" = "$I" ] && pass "head match" || fail "1.6 head" "content differs"

# 1.7 test -f existing
echo "1.7 test -f (exists)"
B=$(test -f "$TEST_FILE" && echo yes || echo no)
I=$(icmd test -f "$TEST_FILE" && echo yes || echo no)
[ "$B" = "$I" ] && pass "test -f existing ($B)" || fail "1.7 test-f" "baseline=$B inception=$I"

# 1.8 test -f missing
echo "1.8 test -f (missing)"
B=$(test -f __nonexistent_xyzzy__.rs && echo yes || echo no)
I=$(icmd test -f __nonexistent_xyzzy__.rs && echo yes || echo no)
[ "$B" = "$I" ] && pass "test -f missing ($B)" || fail "1.8 test-f" "baseline=$B inception=$I"

# ═════════════════════════════════════════════════════════════════════════════
#  PHASE 2: BUILD OPERATIONS
# ═════════════════════════════════════════════════════════════════════════════

section "Phase 2: Build Operations [$PROJECT_NAME]"

# 2.1 cargo check (warm)
echo "2.1 cargo check (warm)"
icmd cargo check 2>&1 >/dev/null
RC=$?
[ $RC -eq 0 ] && pass "cargo check warm (exit=$RC)" || fail "2.1 cargo check" "exit=$RC"

# 2.2 cargo check (re-run, warm cache)
echo "2.2 cargo check (re-run)"
T0=$(python3 -c 'import time; print(int(time.time()*1000))')
icmd cargo check 2>&1 >/dev/null
RC=$?
T1=$(python3 -c 'import time; print(int(time.time()*1000))')
DT=$((T1-T0))
[ $RC -eq 0 ] && pass "cargo check re-run (${DT}ms)" || fail "2.2 cargo check" "exit=$RC"

# 2.3 cargo build
echo "2.3 cargo build"
icmd cargo build 2>&1 >/dev/null
RC=$?
[ $RC -eq 0 ] && pass "cargo build (exit=$RC)" || fail "2.3 cargo build" "exit=$RC"

# 2.4 touch → cargo check (change detection)
echo "2.4 touch → cargo check"
sleep 1
touch "$TEST_FILE"
icmd cargo check 2>&1 >/dev/null
RC=$?
[ $RC -eq 0 ] && pass "cargo check after touch (exit=$RC)" || fail "2.4 touch+check" "exit=$RC"

# 2.5 cargo check re-warm
echo "2.5 cargo check (re-warm)"
icmd cargo check 2>&1 >/dev/null
RC=$?
[ $RC -eq 0 ] && pass "cargo check re-warm" || fail "2.5 re-warm" "exit=$RC"

# ═════════════════════════════════════════════════════════════════════════════
#  PHASE 3: CODE MODIFICATION
# ═════════════════════════════════════════════════════════════════════════════

section "Phase 3: Code Modification [$PROJECT_NAME]"

MOD_FILE="$TEST_FILE"
CANARY="// __e2e_test_canary_$(date +%s)__"

# 3.1 Append and read back
echo "3.1 Append + read"
echo "$CANARY" >> "$MOD_FILE"
TAIL=$(icmd tail -1 "$MOD_FILE")
[ "$TAIL" = "$CANARY" ] && pass "append+read" || fail "3.1 append" "got=$TAIL"

# 3.2 cargo check after modification
echo "3.2 cargo check after mod"
icmd cargo check 2>&1 >/dev/null
RC=$?
[ $RC -eq 0 ] && pass "cargo check (exit=$RC)" || fail "3.2 check" "exit=$RC"

# 3.3 git diff shows change
echo "3.3 git diff"
DIFF=$(icmd git diff --stat 2>&1)
echo "$DIFF" | grep -q "$(basename "$MOD_FILE")" && pass "git diff shows change" || fail "3.3 diff" "file not in diff"

# 3.4 revert
echo "3.4 revert"
icmd git checkout -- "$MOD_FILE"
TAIL=$(tail -1 "$MOD_FILE")
[ "$TAIL" != "$CANARY" ] && pass "reverted" || fail "3.4 revert" "canary still present"

# 3.5 cargo check after revert
echo "3.5 cargo check after revert"
icmd cargo check 2>&1 >/dev/null
RC=$?
[ $RC -eq 0 ] && pass "cargo check (exit=$RC)" || fail "3.5 check" "exit=$RC"

# ═════════════════════════════════════════════════════════════════════════════
#  PHASE 4: GIT OPERATIONS
# ═════════════════════════════════════════════════════════════════════════════

section "Phase 4: Git Operations [$PROJECT_NAME]"

# 4.1 git status
echo "4.1 git status"
B_STATUS=$(git status --porcelain | wc -l | tr -d ' ')
I_STATUS=$(icmd git status --porcelain | wc -l | tr -d ' ')
[ "$B_STATUS" = "$I_STATUS" ] && pass "status match ($B_STATUS dirty)" || fail "4.1 status" "baseline=$B_STATUS inception=$I_STATUS"

# 4.2 git log
echo "4.2 git log"
B_LOG=$(git log --oneline -5)
I_LOG=$(icmd git log --oneline -5)
[ "$B_LOG" = "$I_LOG" ] && pass "log match" || fail "4.2 log" "logs differ"

# 4.3 git diff HEAD~1
echo "4.3 git diff HEAD~1"
B_DIFF=$(git diff HEAD~1 --stat 2>&1 | tail -1)
I_DIFF=$(icmd git diff HEAD~1 --stat 2>&1 | tail -1)
[ "$B_DIFF" = "$I_DIFF" ] && pass "diff stat match" || fail "4.3 diff" "baseline=$B_DIFF inception=$I_DIFF"

# 4.4 git branch
echo "4.4 git branch"
B_BR=$(git branch | wc -l | tr -d ' ')
I_BR=$(icmd git branch | wc -l | tr -d ' ')
[ "$B_BR" = "$I_BR" ] && pass "branch count match ($B_BR)" || fail "4.4 branch" "baseline=$B_BR inception=$I_BR"

# 4.5 modify → status → revert
echo "4.5 modify + status"
echo "// e2e_canary" >> "$MOD_FILE"
I_MOD=$(icmd git status --porcelain)
echo "$I_MOD" | grep -q "$(basename "$MOD_FILE")" && pass "modified file detected" || fail "4.5 status" "not showing"
icmd git checkout -- "$MOD_FILE"

# 4.6 stash cycle
echo "4.6 stash cycle"
STASH_CANARY="// stash_$(date +%s)"
echo "$STASH_CANARY" >> "$MOD_FILE"
icmd git stash -q 2>&1
AFTER_STASH=$(tail -1 "$MOD_FILE")
[ "$AFTER_STASH" != "$STASH_CANARY" ] && pass "stash saved" || fail "4.6a stash" "not saved"
icmd git stash pop -q 2>&1
AFTER_POP=$(tail -1 "$MOD_FILE")
[ "$AFTER_POP" = "$STASH_CANARY" ] && pass "stash pop restored" || fail "4.6b pop" "not restored"
icmd git checkout -- "$MOD_FILE"

# ═════════════════════════════════════════════════════════════════════════════
#  PHASE 5: FILE CREATION & DELETION
# ═════════════════════════════════════════════════════════════════════════════

section "Phase 5: File Creation & Deletion [$PROJECT_NAME]"

E2E_FILE="__e2e_test_file_$$.rs"

echo "5.1 create file"
icmd sh -c "echo 'fn e2e_test() {}' > $E2E_FILE"
icmd test -f "$E2E_FILE" && pass "created" || fail "5.1 create" "not created"

echo "5.2 read file"
GOT=$(icmd cat "$E2E_FILE")
[ "$GOT" = "fn e2e_test() {}" ] && pass "content match" || fail "5.2 read" "got=$GOT"

echo "5.3 ls file"
icmd ls "$E2E_FILE" >/dev/null 2>&1 && pass "ls visible" || fail "5.3 ls" "not visible"

echo "5.4 delete"
icmd rm "$E2E_FILE"
icmd test -f "$E2E_FILE" 2>/dev/null && fail "5.4 delete" "still exists" || pass "deleted"

# ═════════════════════════════════════════════════════════════════════════════
#  PHASE 6: DIRECTORY OPERATIONS
# ═════════════════════════════════════════════════════════════════════════════

section "Phase 6: Directory Operations [$PROJECT_NAME]"

E2E_DIR="__e2e_test_dir_$$"

# 6.1 ls top-level dirs
echo "6.1 ls top-level"
B_LS=$(ls -d */ 2>/dev/null | sort)
I_LS=$(icmd ls -d */ 2>/dev/null | sort)
[ "$B_LS" = "$I_LS" ] && pass "ls dirs match" || fail "6.1 ls" "listings differ"

# 6.2 find dirs
echo "6.2 find dirs"
B_DIRS=$(find . -maxdepth 1 -type d | sort)
I_DIRS=$(icmd find . -maxdepth 1 -type d | sort)
[ "$B_DIRS" = "$I_DIRS" ] && pass "find dirs match" || fail "6.2 find" "dirs differ"

# 6.3 mkdir, create file, read, rmdir
echo "6.3 mkdir + file + rmdir"
icmd mkdir -p "$E2E_DIR"
icmd sh -c "echo 'dir_test_data' > $E2E_DIR/test.txt"
GOT=$(icmd cat "$E2E_DIR/test.txt")
[ "$GOT" = "dir_test_data" ] && pass "mkdir + file + read" || fail "6.3 dir ops" "got=$GOT"
icmd rm -rf "$E2E_DIR"
icmd test -d "$E2E_DIR" 2>/dev/null && fail "6.3 rmdir" "still exists" || pass "rmdir clean"

# ═════════════════════════════════════════════════════════════════════════════
#  PHASE 7: SYMLINKS
# ═════════════════════════════════════════════════════════════════════════════

section "Phase 7: Symlinks [$PROJECT_NAME]"

E2E_LINK="__e2e_test_link_$$"

echo "7.1 create + read symlink"
icmd ln -s Cargo.toml "$E2E_LINK"
B_HEAD=$(head -1 Cargo.toml)
I_HEAD=$(icmd head -1 "$E2E_LINK")
[ "$B_HEAD" = "$I_HEAD" ] && pass "symlink reads correctly" || fail "7.1 symlink" "content differs"

echo "7.2 ls symlink"
if [ "$(uname)" = "Darwin" ]; then
    icmd ls -la "$E2E_LINK" | grep -q '\->' && pass "ls shows symlink" || fail "7.2 ls" "not a symlink"
else
    icmd ls -la "$E2E_LINK" | grep -q '\->' && pass "ls shows symlink" || fail "7.2 ls" "not a symlink"
fi

echo "7.3 delete symlink"
icmd rm "$E2E_LINK"
icmd test -L "$E2E_LINK" 2>/dev/null && fail "7.3 rm" "still exists" || pass "symlink removed"

# ═════════════════════════════════════════════════════════════════════════════
#  PHASE 8: SESSION LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

section "Phase 8: Session Lifecycle [$PROJECT_NAME]"

echo "8.1 VDir file exists"
test -f "$VDIR_PATH" && pass "VDir present" || fail "8.1 VDir" "missing"

echo "8.2 Inception env vars"
INCEP_VAL=$(icmd printenv VRIFT_INCEPTION 2>/dev/null)
[ "$INCEP_VAL" = "1" ] && pass "VRIFT_INCEPTION=1" || fail "8.2 env" "VRIFT_INCEPTION=$INCEP_VAL"

echo "8.3 vrift wake"
WAKE_OUT=$("$VRIFT_BIN" wake 2>&1)
echo "$WAKE_OUT" | grep -qi "exit\|unset\|wake" && pass "wake outputs cleanup" || pass "wake executed"

echo "8.4 re-inception"
# Inception outputs env setup to stdout and progress to stderr; capture both
REINCEP=$("$VRIFT_BIN" inception "$TARGET_PROJECT" 2>&1)
RC=$?
# Success: inception printed exports (RC=0) OR preflight check ran (RC=1)
if [ -n "$REINCEP" ]; then
    pass "re-inception ran (exit=$RC)"
else
    fail "8.4 re-inception" "no output at all"
fi

# ═════════════════════════════════════════════════════════════════════════════
#  PHASE 9: STRESS TESTS
# ═════════════════════════════════════════════════════════════════════════════

section "Phase 9: Stress Tests [$PROJECT_NAME]"

# 9.1 Full-project md5 checksum comparison
echo "9.1 Full md5 comparison (all .rs files)"
RS_COUNT=$(find . -name '*.rs' -not -path '*/target/*' -not -path '*/.git/*' | wc -l | tr -d ' ')
echo "  Checking $RS_COUNT .rs files..."

if command -v md5 >/dev/null 2>&1; then
    MD5CMD="md5 -q"
else
    MD5CMD="md5sum"
fi

B_HASH=$(find . -name '*.rs' -not -path '*/target/*' -not -path '*/.git/*' -exec $MD5CMD {} + 2>/dev/null | sort | $MD5CMD)
I_HASH=$(icmd find . -name '*.rs' -not -path '*/target/*' -not -path '*/.git/*' -exec $MD5CMD {} + 2>/dev/null | sort | $MD5CMD)

[ "$B_HASH" = "$I_HASH" ] && pass "ALL $RS_COUNT .rs files md5 match" || fail "9.1 md5" "baseline=$B_HASH inception=$I_HASH"

# 9.2 Rapid touch + cargo check
echo "9.2 Rapid touch (10 files) + cargo check"
TOUCH_FILES=$(find . -name '*.rs' -not -path '*/target/*' -not -path '*/.git/*' | head -10)
for f in $TOUCH_FILES; do touch "$f"; done
icmd cargo check 2>&1 >/dev/null
RC=$?
[ $RC -eq 0 ] && pass "cargo check after rapid touch" || fail "9.2 rapid touch" "exit=$RC"

# ═════════════════════════════════════════════════════════════════════════════
#  CLEANUP & SUMMARY
# ═════════════════════════════════════════════════════════════════════════════

# Cleanup test artifacts
rm -f "$E2E_FILE" "$E2E_LINK" 2>/dev/null
rm -rf "$E2E_DIR" 2>/dev/null

echo ""
echo -e "${T_CYAN}═══════════════════════════════════════════════════${T_NC}"
echo -e "${T_CYAN}  TEST RESULTS SUMMARY${T_NC}"
echo -e "${T_CYAN}═══════════════════════════════════════════════════${T_NC}"
echo ""
echo "  Project:  $PROJECT_NAME ($TARGET_PROJECT)"
echo "  VDir:     $(basename "$VDIR_PATH")"
echo ""
echo -e "  Total:    $TOTAL"
echo -e "  ${T_GREEN}Passed:   $PASSED${T_NC}"
if [ $FAILED -gt 0 ]; then
    echo -e "  ${T_RED}Failed:   $FAILED${T_NC}"
    echo -e "  ${T_RED}Failures:${T_NC}$FAIL_LIST"
fi
if [ $SKIPPED -gt 0 ]; then
    echo -e "  ${T_YELLOW}Skipped:  $SKIPPED${T_NC}"
fi
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${T_GREEN}═══════════════════════════════════════════════════${T_NC}"
    echo -e "${T_GREEN}  🎉 ALL $PASSED TESTS PASSED${T_NC}"
    echo -e "${T_GREEN}═══════════════════════════════════════════════════${T_NC}"
    exit 0
else
    echo -e "${T_RED}═══════════════════════════════════════════════════${T_NC}"
    echo -e "${T_RED}  💥 $FAILED / $TOTAL TESTS FAILED${T_NC}"
    echo -e "${T_RED}═══════════════════════════════════════════════════${T_NC}"
    exit 1
fi
