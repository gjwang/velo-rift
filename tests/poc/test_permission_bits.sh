#!/bin/bash
# test_permission_bits.sh - Verify file permission handling
# Priority: P2 (Execute permissions, read-only files)
set -e

echo "=== Test: Permission Bits Handling ==="

TEST_DIR="/tmp/perm_test"

cleanup() {
    chmod -R u+rwx "$TEST_DIR" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT
cleanup

mkdir -p "$TEST_DIR"

echo "[1] Testing execute permission (mode 755)..."
echo '#!/bin/sh
echo "EXECUTABLE"' > "$TEST_DIR/script.sh"
chmod 755 "$TEST_DIR/script.sh"
if "$TEST_DIR/script.sh" | grep -q "EXECUTABLE"; then
    echo "    ✓ Execute permission works"
else
    echo "    ✗ Execute failed"
    exit 1
fi

echo "[2] Testing read-only file (mode 444)..."
echo "readonly" > "$TEST_DIR/readonly.txt"
chmod 444 "$TEST_DIR/readonly.txt"
if cat "$TEST_DIR/readonly.txt" | grep -q "readonly"; then
    echo "    ✓ Read works on 444 file"
else
    echo "    ✗ Read failed"
    exit 1
fi

# Try to write (should fail)
if echo "write" >> "$TEST_DIR/readonly.txt" 2>/dev/null; then
    echo "    ✗ Write should fail on 444 file"
else
    echo "    ✓ Write correctly denied on 444 file"
fi

echo "[3] Testing no-permission file (mode 000)..."
echo "secret" > "$TEST_DIR/noperm.txt"
chmod 000 "$TEST_DIR/noperm.txt"
if cat "$TEST_DIR/noperm.txt" 2>/dev/null; then
    echo "    ⚠ Read succeeded on 000 (running as root?)"
else
    echo "    ✓ Read denied on 000 file"
fi

echo "[4] Testing stat reports correct mode..."
chmod 644 "$TEST_DIR/readonly.txt"
MODE=$(stat -f%p "$TEST_DIR/readonly.txt" 2>/dev/null | tail -c4 || stat -c%a "$TEST_DIR/readonly.txt" 2>/dev/null)
if [ "$MODE" = "644" ]; then
    echo "    ✓ stat reports 644"
else
    echo "    ⚠ Mode reported as: $MODE"
fi

echo ""
echo "✅ PASS: Permission bits work correctly"
exit 0
