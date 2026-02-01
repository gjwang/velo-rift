#!/bin/bash
# pre-push-check.sh - Run all checks before pushing to avoid CI failures

set -e

echo "============================================"
echo "  Pre-Push Validation"
echo "============================================"

# 1. Cargo fmt check
echo ""
echo "→ Checking Rust formatting..."
if ! cargo fmt --all -- --check; then
    echo "❌ Format check failed. Running cargo fmt to fix..."
    cargo fmt --all
    echo "✅ Format fixed. Please review and commit the changes."
    exit 1
fi
echo "✅ Rust formatting OK"

# 2. Clippy check
echo ""
echo "→ Running clippy..."
if [[ "$(uname)" == "Darwin" ]]; then
    # Skip io_uring on macOS
    if ! cargo clippy --workspace --all-targets -- -D warnings; then
        echo "❌ Clippy check failed."
        exit 1
    fi
else
    # Linux: check all features (including io_uring)
    if ! cargo clippy --workspace --all-targets --all-features -- -D warnings; then
        echo "❌ Clippy check failed."
        exit 1
    fi
fi
echo "✅ Clippy OK"

# 3. Python formatting (if needed)
echo "→ Running pre-commit (includes ruff & mypy)..."
if ! uv run pre-commit run --all-files; then
    echo "❌ Pre-commit failed. Please fix the errors above."
    exit 1
fi
echo "✅ Python checks OK"

echo ""
echo "============================================"
echo "  ✅ All checks passed! Safe to push."
echo "============================================"
