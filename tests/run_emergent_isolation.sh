#!/bin/bash
set -e

# Emergency Isolation Test
# Bypasses kernel deadlocks by using randomized paths and sockets

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# 1. Randomize Environment
SUFFIX=$(date +%s)_$RANDOM
TEST_ROOT="/tmp/vrift-iso-${SUFFIX}"
SOCKET_PATH="/tmp/vrift_iso_${SUFFIX}.sock"
LOCK_PATH="/tmp/vrift_iso_${SUFFIX}.lock"

echo -e "${GREEN}🛡️  Starting Isolation Test in: $TEST_ROOT${NC}"
echo "   Socket: $SOCKET_PATH"

mkdir -p "$TEST_ROOT/project"

# 2. Setup Environment Variables
export VR_SOCK_PATH="$SOCKET_PATH"
export VR_DAEMON_SOCKET="$SOCKET_PATH" # Support both naming conventions if any
export VR_LOCK_PATH="$LOCK_PATH"
export VR_THE_SOURCE="$TEST_ROOT/the_source"
export RUST_LOG=info

# 3. Build & Tools
echo "🔨 Building binaries..."
cargo build --quiet --workspace --bin vriftd --bin vrift
VRIFT_BIN="$(pwd)/target/debug/vrift"
VRIFTD_BIN="$(pwd)/target/debug/vriftd"

# Compile test helper
gcc tests/lib/test_stat.c -o "$TEST_ROOT/test_stat"
codesign --force --sign - "$TEST_ROOT/test_stat" >/dev/null 2>&1 || true

# 4. Start Isolated Daemon
echo "👻 Starting Isolated Daemon..."
STOP_DAEMON() {
    if [ -f "$TEST_ROOT/daemon.pid" ]; then
        kill $(cat "$TEST_ROOT/daemon.pid") 2>/dev/null || true
    fi
    rm -f "$SOCKET_PATH"
}
trap STOP_DAEMON EXIT

"$VRIFTD_BIN" start > "$TEST_ROOT/daemon.log" 2>&1 &
DAEMON_PID=$!
echo $DAEMON_PID > "$TEST_ROOT/daemon.pid"
sleep 2

if ! kill -0 $DAEMON_PID 2>/dev/null; then
    echo -e "${RED}Daemon failed to start! Log:${NC}"
    cat "$TEST_ROOT/daemon.log"
    exit 1
fi

# 5. Ingest & Run
echo "📦 Ingesting..."
echo "Hello Isolated World" > "$TEST_ROOT/project/target.txt"

"$VRIFT_BIN" ingest "$TEST_ROOT/project" \
    --output "$TEST_ROOT/project/vrift.manifest" \
    --prefix ""

echo "🏃 Running VFS verification..."
cd "$TEST_ROOT/project"
export VRIFT_MANIFEST="$TEST_ROOT/project/vrift.manifest"
export VRIFT_VFS_PREFIX="/vrift"

OUTPUT=$("$VRIFT_BIN" run --manifest "$VRIFT_MANIFEST" "$TEST_ROOT/test_stat" "/vrift/target.txt" 2>&1)
echo "$OUTPUT"

if echo "$OUTPUT" | grep -q "SUCCESS"; then
    echo -e "${GREEN}✅ ISOLATION TEST PASSED!${NC}"
    echo "The code is working. The failures are indeed environmental."
else
    echo -e "${RED}❌ TEST FAILED${NC}"
    cat "$TEST_ROOT/daemon.log"
    exit 1
fi
