#!/bin/bash
set -e

MODE="host"

if [[ "$1" == "--docker" ]]; then
    MODE="docker"
fi

echo "=== Velo Rift Local CI ($MODE) ==="

if [[ "$MODE" == "docker" ]]; then
    # Docker Mode
    # Optimization: Skip base build if it exists, unless --rebuild-base is passed
    if [[ "$(docker images -q vrift-ci-base 2> /dev/null)" == "" ]] || [[ "$@" == *"--rebuild-base"* ]]; then
        echo "[*] Building Base Image (Layer Caching Enabled)..."
        docker build -t vrift-ci-base -f Dockerfile.base .
    else
        echo "[*] Base Image 'vrift-ci-base' found. Skipping build (Use --rebuild-base to force)."
    fi

    # Optimization: Use Bind Mounts for code and artifacts
    # This avoids 'docker build' and 'exporting layers' entirely for source changes.
    echo "[*] Running Test Suite with Bind Mounts..."
    
    # Ensure volumes exist for caching
    docker volume create vrift-cargo-registry > /dev/null
    docker volume create vrift-target-cache > /dev/null
    docker volume create vrift-rustup > /dev/null

    # Run directly in base image (or previous e2e image if dependencies stick)
    # We use vrift-ci-base because it has the tools.
    # -v $(pwd):/workspace: Mounts current code
    # -v vrift-target-cache:/workspace/target: Persists compilation artifacts across runs
    # -v vrift-cargo-registry:/usr/local/cargo/registry: Persists downloaded crates
    # -v vrift-rustup:/usr/local/rustup: Persists rustup toolchains
    docker run --rm --privileged \
        --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor:unconfined \
        -v "$(pwd)":/workspace \
        -v vrift-cargo-registry:/usr/local/cargo/registry \
        -v vrift-target-cache:/workspace/target \
        -v vrift-rustup:/usr/local/rustup \
        -w /workspace \
        -e CI=true \
        -e VR_THE_SOURCE=/tmp/vrift_cas \
        vrift-ci-base \
        /bin/bash -c "cd /workspace && ./test.sh"
else
    # Host Mode (macOS/Linux)
    echo "[*] Running Test Suite on Host..."
    ./test.sh
fi

echo "=== Local CI Passed ==="
