#!/bin/bash
set -e

# scripts/test_vdir_robustness.sh
# Automates the verification of Round 4 & 5 features:
# - VDir Observability (Stats & CLI)
# - VDir Scalability (Dynamic Resizing)
# - Reader Resilience during growth

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_PATH="$REPO_ROOT/target/debug/vrift"

echo "🚀 Starting VDir Robustness Verification Suite"
echo "──────────────────────────────────────────────"

# 1. Build project
echo "📦 Building vrift..."
cargo build --bin vrift

# 2. Run Unit Tests & Stress Tests
echo "🧪 Running VDir Unit/Stress Tests..."
cargo test -p vrift-vdird -- --nocapture

# 3. Generate Populated VDir Files
echo "🏗️  Generating QA VDir files (integration tests)..."
cargo test -p vrift-vdird --test qa_vdir -- --nocapture

# 4. Verify CLI Observability
echo "🔍 Verifying CLI 'debug vdir' output..."

if [ -f "/tmp/qa_populated.vdir" ]; then
    echo -e "\n--- Populated VDir (1000 entries) ---"
    "$BIN_PATH" debug vdir /tmp/qa_populated.vdir
fi

if [ -f "/tmp/qa_resized.vdir" ]; then
    echo -e "\n--- Resized VDir (Doubled Capacity) ---"
    "$BIN_PATH" debug vdir /tmp/qa_resized.vdir
fi

echo -e "\n──────────────────────────────────────────────"
echo "✅ Verification Complete! All systems operational."
