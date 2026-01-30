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
    if [[ "$(docker images -q velo-ci-base 2> /dev/null)" == "" ]] || [[ "$@" == *"--rebuild-base"* ]]; then
        echo "[*] Building Base Image (Layer Caching Enabled)..."
        docker build -t velo-ci-base -f Dockerfile.base .
    else
        echo "[*] Base Image 'velo-ci-base' found. Skipping build (Use --rebuild-base to force)."
    fi

    # Optimization: Use Bind Mounts for code and artifacts
    # This avoids 'docker build' and 'exporting layers' entirely for source changes.
    echo "[*] Running Test Suite with Bind Mounts..."
    
    # Ensure volumes exist for caching
    docker volume create v_rift_cargo_registry > /dev/null
    docker volume create v_rift_target_cache > /dev/null
    docker volume create v_rift_rustup > /dev/null

    # Run directly in base image (or previous e2e image if dependencies stick)
    # We use velo-ci-base because it has the tools.
    # -v $(pwd):/workspace: Mounts current code
    # -v v_rift_target_cache:/workspace/target: Persists compilation artifacts across runs
    # -v v_rift_cargo_registry:/usr/local/cargo/registry: Persists downloaded crates
    # -v v_rift_rustup:/usr/local/rustup: Persists rustup toolchains
    docker run --rm --privileged \
        --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor:unconfined \
        -v "$(pwd)":/workspace \
        -v v_rift_cargo_registry:/usr/local/cargo/registry \
        -v v_rift_target_cache:/workspace/target \
        -v v_rift_rustup:/usr/local/rustup \
        -w /workspace \
        -e CI=true \
        -e VR_THE_SOURCE=/tmp/v_rift_cas \
        velo-ci-base \
        /bin/bash -c "cd /workspace && ./test.sh"
else
    # Host Mode (macOS/Linux)
    echo "[*] Running Test Suite on Host..."
    ./test.sh
fi

echo "=== Local CI Passed ==="
