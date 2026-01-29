#!/bin/bash
set -e

echo "=== Velo Rift Local CI ==="

# 1. Build Base Image (cached)
echo "[*] Building Base Image..."
docker build -t velo-ci-base -f Dockerfile.base .

# 2. Build CI Image
echo "[*] Building CI Image..."
docker build -t velo-ci-e2e -f Dockerfile.ci .

# 3. Run Tests
echo "[*] Running Test Suite..."
docker run --rm --privileged velo-ci-e2e

echo "=== Local CI Passed ==="
