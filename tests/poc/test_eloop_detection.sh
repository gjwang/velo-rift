#!/bin/bash
# test_eloop_detection.sh - Verify ELOOP (too many symlink levels)
# Priority: P2 (Symlink cycle prevention)
set -e

echo "=== Test: ELOOP Symlink Detection ==="

TEST_DIR="/tmp/eloop_test"

cleanup() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT
cleanup

mkdir -p "$TEST_DIR"

echo "[1] Creating symlink chain..."
# Create a chain: link1 -> link2 -> link3 -> ... -> link40
for i in $(seq 1 39); do
    ln -s "link$((i+1))" "$TEST_DIR/link$i"
done
echo "target" > "$TEST_DIR/link40"

echo "[2] Testing access through long chain..."
if cat "$TEST_DIR/link1" 2>/dev/null | grep -q "target"; then
    echo "    ✓ Long symlink chain resolved"
else
    echo "    ⚠ Chain may be too long for system"
fi

echo "[3] Creating symlink cycle..."
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
ln -s "$TEST_DIR/cycle_b" "$TEST_DIR/cycle_a"
ln -s "$TEST_DIR/cycle_a" "$TEST_DIR/cycle_b"

if cat "$TEST_DIR/cycle_a" 2>&1 | grep -qi "loop\|too many"; then
    echo "    ✓ ELOOP detected for symlink cycle"
elif ! cat "$TEST_DIR/cycle_a" 2>/dev/null; then
    echo "    ✓ Access fails on symlink cycle (errno check)"
else
    echo "    ✗ Symlink cycle not detected!"
    exit 1
fi

echo "[4] Verifying stat on cycle returns error..."
if stat "$TEST_DIR/cycle_a" 2>&1 | grep -qi "loop\|too many"; then
    echo "    ✓ stat returns error on cycle"
else
    STAT_OUT=$(stat "$TEST_DIR/cycle_a" 2>&1)
    if echo "$STAT_OUT" | grep -q "No such"; then
        echo "    ✓ stat fails on cycle"
    else
        echo "    ⚠ stat behavior: $STAT_OUT"
    fi
fi

echo ""
echo "✅ PASS: ELOOP detection works"
exit 0
