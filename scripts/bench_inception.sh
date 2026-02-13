#!/bin/bash
# ==============================================================================
# bench_inception.sh — Inception Layer Performance Benchmark
#
# Measures the overhead and acceleration of the VFS inception shim across
# multiple build scenarios. By default benchmarks the velo project; pass
# arguments to benchmark any Rust project with an active VDir.
#
# Usage:
#   ./scripts/bench_inception.sh                        # defaults to ../velo
#   ./scripts/bench_inception.sh /path/to/project       # custom project
#   ./scripts/bench_inception.sh /path/to/project src/lib.rs  # custom touch file
#
# Requirements:
#   - Release build of libvrift_inception_layer.dylib (or .so)
#   - A running vriftd daemon with a populated VDir for the target project
#   - The target project must have been ingested (vrift ingest)
#
# What it measures:
#   1. Baseline no-op     — cargo build without inception (warm cache)
#   2. Inception no-op    — cargo build with inception shim (measures shim overhead)
#   3. Touch incremental  — touch a source file, rebuild (incremental + shim)
#   4. Code incremental   — actual code change, rebuild (incremental + shim)
#   5. Source read stress  — stat+read all source files via inception (CAS accel)
#
# ==============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

PROJECT_DIR="${1:-/Users/antigravity/rust_source/velo}"
TOUCH_FILE="${2:-}"
ITERATIONS="${BENCH_ITERATIONS:-3}"

# Resolve project dir to absolute path
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"

# Source SSOT env vars
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RIFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT="$RIFT_ROOT"
source "$RIFT_ROOT/tests/lib/vrift_env.sh"

if [[ "$(uname)" == "Darwin" ]]; then
    SHIM_NAME="libvrift_inception_layer.dylib"
    DYLD_VAR="DYLD_INSERT_LIBRARIES"
    DYLD_FLAT="DYLD_FORCE_FLAT_NAMESPACE"
else
    SHIM_NAME="libvrift_inception_layer.so"
    DYLD_VAR="LD_PRELOAD"
    DYLD_FLAT=""
fi

# Search order: release > debug > project-local
SHIM=""
for candidate in \
    "$RIFT_ROOT/target/release/$SHIM_NAME" \
    "$RIFT_ROOT/target/debug/$SHIM_NAME" \
    "$PROJECT_DIR/.vrift/$SHIM_NAME"; do
    if [[ -f "$candidate" ]]; then
        SHIM="$candidate"
        break
    fi
done

if [[ -z "$SHIM" ]]; then
    echo "ERROR: Cannot find $SHIM_NAME. Build with: cargo build --release -p vrift-inception-layer"
    exit 1
fi

# Auto-detect VDir mmap path from project ID
# The Rust shim uses blake3(project_root)[..8].to_hex() = 16 hex chars
VDIR=""
if command -v b3sum &>/dev/null; then
    PROJECT_ID=$(echo -n "$PROJECT_DIR" | b3sum --no-names | head -c 16)
    CANDIDATE="$HOME/.vrift/vdir/${PROJECT_ID}.vdir"
    if [[ -f "$CANDIDATE" ]]; then
        VDIR="$CANDIDATE"
    fi
fi

# Fallback: use the vrift binary to derive the VDir path
if [[ -z "$VDIR" ]]; then
    VRIFT_BIN="$RIFT_ROOT/target/release/vrift"
    if [[ -x "$VRIFT_BIN" ]]; then
        VDIR=$($VRIFT_BIN config get vdir_path 2>/dev/null || echo "")
    fi
fi

# Fallback: find most recently modified .vdir file
if [[ -z "$VDIR" ]] && [[ -d "$HOME/.vrift/vdir" ]]; then
    VDIR=$(ls -t "$HOME/.vrift/vdir/"*.vdir 2>/dev/null | head -1 || echo "")
fi

# Auto-detect the source file to touch
if [[ -z "$TOUCH_FILE" ]]; then
    # Try common locations first
    for candidate in "src/lib.rs" "src/main.rs"; do
        if [[ -f "$PROJECT_DIR/$candidate" ]]; then
            TOUCH_FILE="$candidate"
            break
        fi
    done
    # Fallback: find a lib.rs in any crate, convert to relative path
    if [[ -z "$TOUCH_FILE" ]]; then
        ABS_PATH=$(find "$PROJECT_DIR" -maxdepth 4 -name 'lib.rs' -path '*/src/*' \
            -not -path '*/target/*' 2>/dev/null | head -1)
        if [[ -n "$ABS_PATH" ]]; then
            TOUCH_FILE="${ABS_PATH#$PROJECT_DIR/}"
        fi
    fi
fi

if [[ -z "$TOUCH_FILE" ]] || [[ ! -f "$PROJECT_DIR/$TOUCH_FILE" ]]; then
    echo "WARNING: No source file found to touch. Touch/Code-change tests will be skipped."
    TOUCH_FILE=""
fi

# Socket path (from SSOT helper)
SOCK="$VRIFT_SOCKET_PATH"

# CAS root (from SSOT helper)
CAS_ROOT="$VR_THE_SOURCE"

# ── Helpers ───────────────────────────────────────────────────────────────────

ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

INCEP() {
    local env_args=(
        "VRIFT_PROJECT_ROOT=$PROJECT_DIR"
        "VRIFT_VFS_PREFIX=$PROJECT_DIR"
        "VRIFT_SOCKET_PATH=$SOCK"
        "VR_THE_SOURCE=$CAS_ROOT"
        "VRIFT_INCEPTION=1"
    )

    if [[ -n "$VDIR" ]]; then
        env_args+=("VRIFT_VDIR_MMAP=$VDIR")
    fi

    env_args+=("$DYLD_VAR=$SHIM")
    if [[ -n "$DYLD_FLAT" ]]; then
        env_args+=("$DYLD_FLAT=1")
    fi

    env "${env_args[@]}" "$@"
}

run_bench() {
    local label="$1"
    shift
    local times=()

    echo ""
    echo "── $label ──"
    for i in $(seq 1 "$ITERATIONS"); do
        T0=$(ms)
        eval "$@"
        T1=$(ms)
        local elapsed=$((T1 - T0))
        times+=("$elapsed")
        echo "  Run $i: ${elapsed}ms"
    done

    # Calculate average
    local sum=0
    for t in "${times[@]}"; do sum=$((sum + t)); done
    local avg=$((sum / ITERATIONS))
    echo "  Avg: ${avg}ms"
}

# ── Main ──────────────────────────────────────────────────────────────────────

PROJECT_NAME=$(basename "$PROJECT_DIR")

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  Inception Layer Benchmark                                      ║"
echo "╠═══════════════════════════════════════════════════════════════════╣"
echo "║  Project:    $PROJECT_DIR"
echo "║  Shim:       $SHIM"
echo "║  VDir:       ${VDIR:-NONE (no CAS acceleration)}"
echo "║  Socket:     $SOCK"
echo "║  Touch file: ${TOUCH_FILE:-NONE}"
echo "║  Iterations: $ITERATIONS"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""

cd "$PROJECT_DIR"

# Result accumulators
BASELINE_NOOP_AVG=0
INCEPTION_NOOP_AVG=0
BASELINE_TOUCH_AVG=0
INCEPTION_TOUCH_AVG=0
BASELINE_CODE_AVG=0
INCEPTION_CODE_AVG=0
STAT_BASELINE=0
STAT_INCEPTION=0
READ_BASELINE=0
READ_INCEPTION=0
SRC_COUNT=0

# Warmup — ensure cargo index is cached
echo "Warming up ($PROJECT_NAME)..."
cargo build >/dev/null 2>&1 || true
echo ""

# ── 1) Baseline no-op ────────────────────────────────────────────────────────
echo ""
echo "── [$PROJECT_NAME] Baseline no-op (no inception) ──"
times_base=()
for i in $(seq 1 "$ITERATIONS"); do
    T0=$(ms); cargo build >/dev/null 2>&1 || true; T1=$(ms)
    elapsed=$((T1 - T0)); times_base+=("$elapsed")
    echo "  Run $i: ${elapsed}ms"
done
sum=0; for t in "${times_base[@]}"; do sum=$((sum + t)); done
BASELINE_NOOP_AVG=$((sum / ITERATIONS))
echo "  Avg: ${BASELINE_NOOP_AVG}ms"

# ── 2) Inception no-op ───────────────────────────────────────────────────────
echo ""
echo "── [$PROJECT_NAME] Inception no-op (shim loaded) ──"
times_incep=()
for i in $(seq 1 "$ITERATIONS"); do
    T0=$(ms); INCEP cargo build >/dev/null 2>&1 || true; T1=$(ms)
    elapsed=$((T1 - T0)); times_incep+=("$elapsed")
    echo "  Run $i: ${elapsed}ms"
done
sum=0; for t in "${times_incep[@]}"; do sum=$((sum + t)); done
INCEPTION_NOOP_AVG=$((sum / ITERATIONS))
echo "  Avg: ${INCEPTION_NOOP_AVG}ms"

# ── 3) Touch incremental (baseline vs inception) ─────────────────────────────
if [[ -n "$TOUCH_FILE" ]]; then
    echo ""
    echo "── [$PROJECT_NAME] Touch incremental (BASELINE) — $TOUCH_FILE ──"
    times_touch_b=()
    for i in $(seq 1 "$ITERATIONS"); do
        sleep 1; touch "$TOUCH_FILE"
        T0=$(ms); cargo build >/dev/null 2>&1 || true; T1=$(ms)
        elapsed=$((T1 - T0)); times_touch_b+=("$elapsed")
        echo "  Run $i: ${elapsed}ms"
    done
    sum=0; for t in "${times_touch_b[@]}"; do sum=$((sum + t)); done
    BASELINE_TOUCH_AVG=$((sum / ITERATIONS))
    echo "  Avg: ${BASELINE_TOUCH_AVG}ms"

    echo ""
    echo "── [$PROJECT_NAME] Touch incremental (INCEPTION) — $TOUCH_FILE ──"
    times_touch_i=()
    for i in $(seq 1 "$ITERATIONS"); do
        sleep 1; touch "$TOUCH_FILE"
        T0=$(ms); INCEP cargo build >/dev/null 2>&1 || true; T1=$(ms)
        elapsed=$((T1 - T0)); times_touch_i+=("$elapsed")
        echo "  Run $i: ${elapsed}ms"
    done
    sum=0; for t in "${times_touch_i[@]}"; do sum=$((sum + t)); done
    INCEPTION_TOUCH_AVG=$((sum / ITERATIONS))
    echo "  Avg: ${INCEPTION_TOUCH_AVG}ms"
fi

# ── 4) Code change incremental (baseline vs inception) ───────────────────────
if [[ -n "$TOUCH_FILE" ]]; then
    cp "$TOUCH_FILE" "${TOUCH_FILE}.bench_bak"

    echo ""
    echo "── [$PROJECT_NAME] Code change incremental (BASELINE) — $TOUCH_FILE ──"
    times_code_b=()
    for i in $(seq 1 "$ITERATIONS"); do
        echo "" >> "$TOUCH_FILE"
        echo "// bench_canary_${i}_$(date +%s)" >> "$TOUCH_FILE"
        T0=$(ms); cargo build >/dev/null 2>&1 || true; T1=$(ms)
        elapsed=$((T1 - T0)); times_code_b+=("$elapsed")
        echo "  Run $i: ${elapsed}ms"
        cp "${TOUCH_FILE}.bench_bak" "$TOUCH_FILE"
        cargo build >/dev/null 2>&1 || true  # restore baseline
    done
    sum=0; for t in "${times_code_b[@]}"; do sum=$((sum + t)); done
    BASELINE_CODE_AVG=$((sum / ITERATIONS))
    echo "  Avg: ${BASELINE_CODE_AVG}ms"

    echo ""
    echo "── [$PROJECT_NAME] Code change incremental (INCEPTION) — $TOUCH_FILE ──"
    times_code_i=()
    for i in $(seq 1 "$ITERATIONS"); do
        echo "" >> "$TOUCH_FILE"
        echo "// bench_canary_${i}_$(date +%s)" >> "$TOUCH_FILE"
        T0=$(ms); INCEP cargo build >/dev/null 2>&1 || true; T1=$(ms)
        elapsed=$((T1 - T0)); times_code_i+=("$elapsed")
        echo "  Run $i: ${elapsed}ms"
        cp "${TOUCH_FILE}.bench_bak" "$TOUCH_FILE"
        INCEP cargo build >/dev/null 2>&1 || true  # restore baseline
    done
    sum=0; for t in "${times_code_i[@]}"; do sum=$((sum + t)); done
    INCEPTION_CODE_AVG=$((sum / ITERATIONS))
    echo "  Avg: ${INCEPTION_CODE_AVG}ms"

    rm -f "${TOUCH_FILE}.bench_bak"
fi

# ── 5) Source read stress (CAS acceleration test) ─────────────────────────────
echo ""
echo "── [$PROJECT_NAME] Source file I/O stress (CAS acceleration) ──"
SRC_COUNT=$(find "$PROJECT_DIR" -name '*.rs' -not -path '*/target/*' -not -path '*/.git/*' | wc -l | tr -d ' ')
echo "  Source files: $SRC_COUNT .rs files"

# Baseline: stat all source files without inception
T0=$(ms)
find "$PROJECT_DIR" -name '*.rs' -not -path '*/target/*' -not -path '*/.git/*' -exec stat {} + >/dev/null 2>&1 || true
T1=$(ms)
STAT_BASELINE=$((T1 - T0))
echo "  Baseline stat-all: ${STAT_BASELINE}ms"

# Inception: stat all source files with inception (should use VDir)
T0=$(ms)
INCEP find "$PROJECT_DIR" -name '*.rs' -not -path '*/target/*' -not -path '*/.git/*' -exec stat {} + >/dev/null 2>&1 || true
T1=$(ms)
STAT_INCEPTION=$((T1 - T0))
echo "  Inception stat-all: ${STAT_INCEPTION}ms"

# Baseline: cat all source files (read content)
T0=$(ms)
find "$PROJECT_DIR" -name '*.rs' -not -path '*/target/*' -not -path '*/.git/*' -exec cat {} + >/dev/null 2>&1 || true
T1=$(ms)
READ_BASELINE=$((T1 - T0))
echo "  Baseline read-all: ${READ_BASELINE}ms"

# Inception: cat all source files (should serve from CAS)
T0=$(ms)
INCEP find "$PROJECT_DIR" -name '*.rs' -not -path '*/target/*' -not -path '*/.git/*' -exec cat {} + >/dev/null 2>&1 || true
T1=$(ms)
READ_INCEPTION=$((T1 - T0))
echo "  Inception read-all: ${READ_INCEPTION}ms"

# ── Summary Table ─────────────────────────────────────────────────────────────
NOOP_RATIO=$(python3 -c "print(f'{$INCEPTION_NOOP_AVG/$BASELINE_NOOP_AVG:.2f}x')" 2>/dev/null || echo "N/A")
if [[ "$STAT_BASELINE" -gt 0 ]]; then
    STAT_RATIO=$(python3 -c "print(f'{$STAT_INCEPTION/$STAT_BASELINE:.2f}x')" 2>/dev/null || echo "N/A")
else
    STAT_RATIO="N/A"
fi
if [[ "$READ_BASELINE" -gt 0 ]]; then
    READ_RATIO=$(python3 -c "print(f'{$READ_INCEPTION/$READ_BASELINE:.2f}x')" 2>/dev/null || echo "N/A")
else
    READ_RATIO="N/A"
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  BENCHMARK SUMMARY                                             ║"
echo "║  Project: $PROJECT_DIR"
echo "║  Source:  $SRC_COUNT .rs files | Iterations: $ITERATIONS"
echo "╠═══════════════════════════════════════════════════════════════════╣"
printf "║  %-32s %8s  %8s  %8s ║\n" "Scenario" "Baseline" "Inception" "Ratio"
echo "║  ────────────────────────────────────────────────────────────── ║"
printf "║  %-32s %7dms  %7dms  %8s ║\n" "No-op build" "$BASELINE_NOOP_AVG" "$INCEPTION_NOOP_AVG" "$NOOP_RATIO"
if [[ -n "$TOUCH_FILE" ]]; then
    TOUCH_RATIO=$(python3 -c "print(f'{$INCEPTION_TOUCH_AVG/$BASELINE_TOUCH_AVG:.2f}x')" 2>/dev/null || echo "N/A")
    CODE_RATIO=$(python3 -c "print(f'{$INCEPTION_CODE_AVG/$BASELINE_CODE_AVG:.2f}x')" 2>/dev/null || echo "N/A")
    printf "║  %-32s %7dms  %7dms  %8s ║\n" "Touch incremental" "$BASELINE_TOUCH_AVG" "$INCEPTION_TOUCH_AVG" "$TOUCH_RATIO"
    printf "║  %-32s %7dms  %7dms  %8s ║\n" "Code change incremental" "$BASELINE_CODE_AVG" "$INCEPTION_CODE_AVG" "$CODE_RATIO"
fi
printf "║  %-32s %7dms  %7dms  %8s ║\n" "Stat-all ($SRC_COUNT files)" "$STAT_BASELINE" "$STAT_INCEPTION" "$STAT_RATIO"
printf "║  %-32s %7dms  %7dms  %8s ║\n" "Read-all ($SRC_COUNT files)" "$READ_BASELINE" "$READ_INCEPTION" "$READ_RATIO"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""

