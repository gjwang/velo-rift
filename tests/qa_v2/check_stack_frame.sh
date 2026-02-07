#!/bin/bash
# CI Guard: Verify InceptionLayerState::get() stack frame stays small
#
# BUG-007b: If init() or open_manifest_mmap() get inlined into get(),
# the combined stack frame exceeds 512KB (macOS default pthread stack),
# causing silent hangs on all worker threads.
#
# This script parses the disassembly and fails if the stack frame > 4096 bytes.

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DYLIB="$PROJECT_ROOT/target/release/libvrift_inception_layer.dylib"

if [ ! -f "$DYLIB" ]; then
    echo "⚠️  Release dylib not found, building..."
    (cd "$PROJECT_ROOT" && cargo build --release -p vrift-inception-layer)
fi

echo "🔍 Checking InceptionLayerState::get() stack frame size..."

# Extract the prologue of get()
PROLOGUE=$(objdump -d "$DYLIB" 2>/dev/null | grep -A 10 "InceptionLayerState.*get.*:" | head -15)

if [ -z "$PROLOGUE" ]; then
    echo "❌ FAILED: Could not find InceptionLayerState::get in dylib"
    exit 1
fi

echo "$PROLOGUE"

# On ARM64, a large stack frame shows as: sub x9, sp, #<large>
# A healthy frame shows as: sub sp, sp, #<small>
# Check for the dangerous pattern: sub x9, sp, # with large immediate
if echo "$PROLOGUE" | grep -q "sub.*x9.*sp.*#[0-9].*lsl.*#12"; then
    # Extract the shifted immediate (value * 4096)
    SHIFT_VAL=$(echo "$PROLOGUE" | grep "sub.*x9.*sp.*#[0-9].*lsl.*#12" | head -1 | \
        sed 's/.*#\([0-9]*\).*lsl.*#12.*/\1/')
    FRAME_SIZE=$((SHIFT_VAL * 4096))
    echo ""
    echo "❌ FAILED: get() stack frame is ${FRAME_SIZE} bytes (limit: 4096)"
    echo "   This means init() or open_manifest_mmap() has been inlined into get()!"
    echo "   Fix: Ensure both have #[inline(never)] attribute."
    exit 1
fi

# Also check for a simple sub sp, sp, #<large> without shift
SIMPLE_SUB=$(echo "$PROLOGUE" | grep "sub.*sp.*sp.*#[0-9]" | head -1 | \
    sed 's/.*#\([0-9]*\)$/\1/' 2>/dev/null || echo "0")
# Remove any trailing non-numeric
SIMPLE_SUB=$(echo "$SIMPLE_SUB" | tr -cd '0-9')
SIMPLE_SUB=${SIMPLE_SUB:-0}

if [ "$SIMPLE_SUB" -gt 4096 ] 2>/dev/null; then
    echo ""
    echo "❌ FAILED: get() stack frame is ${SIMPLE_SUB} bytes (limit: 4096)"
    exit 1
fi

echo ""
echo "✅ get() stack frame is small (${SIMPLE_SUB} bytes) — no inlining detected"
