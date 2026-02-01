#!/usr/bin/env python3
"""
VRift E2E Regression Test Suite

Comprehensive end-to-end tests for zero-copy ingest functionality.
Tests tiered datasets, dedup, EPERM handling, and cross-project dedup.

Usage:
    python3 scripts/e2e_test.py              # Default: shared mode
    python3 scripts/e2e_test.py --isolated   # Each dataset gets independent CAS
    python3 scripts/e2e_test.py --shared     # All datasets share CAS (default)
    python3 scripts/e2e_test.py --incremental # Use persistent CAS, test re-ingest
    python3 scripts/e2e_test.py --full       # Include large/xlarge datasets

Requirements:
    - Python 3.10+
    - Node.js / npm (for dependency installation)
    - Built vrift binary (cargo build --release)
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR = Path(__file__).parent.absolute()
PROJECT_ROOT = SCRIPT_DIR.parent
VRIFT_BINARY = PROJECT_ROOT / "target" / "release" / "vrift"
BENCHMARKS_DIR = PROJECT_ROOT / "examples" / "benchmarks"

# Persistent CAS for incremental mode
PERSISTENT_CAS = Path.home() / ".vrift" / "e2e_test_cas"

# Test datasets (xsmall=extra-small lib, small=app, medium=standard, large=monorepo)
DATASETS = {
    "xsmall": {
        "package": "xsmall_package.json",
        "min_files": 10000,
        "max_time_sec": 10,
    },
    "small": {
        "package": "small_package.json",
        "min_files": 20000,
        "max_time_sec": 15,
    },
    "medium": {
        "package": "medium_package.json",
        "min_files": 50000,
        "max_time_sec": 30,
    },
    "large": {
        "package": "large_package.json",
        "min_files": 200000,
        "max_time_sec": 120,
    },
}

# Monorepo config: packages with their dependencies (matches large_package.json)
# Note: large_package.json is the monorepo, this maps package names to sub-dependencies
MONOREPO_PACKAGES = {
    "web": "medium_package.json",  # Heavy frontend
    "mobile": "small_package.json",  # Mobile app
    "shared": "xsmall_package.json",  # Shared utilities
    "docs": "small_package.json",  # Documentation site
    "storybook": "small_package.json",  # Storybook
}


class TestMode(Enum):
    ISOLATED = "isolated"  # Each dataset gets independent CAS
    SHARED = "shared"  # All datasets share CAS (cross-project dedup)
    INCREMENTAL = "incremental"  # Persistent CAS, test re-ingest speed


@dataclass
class TestResult:
    name: str
    passed: bool
    duration_sec: float
    files: int
    message: str


# ============================================================================
# Utilities
# ============================================================================


def run_cmd(cmd: list[str], cwd: Path | None = None, timeout: int = 600) -> tuple[int, str, str]:
    """Run a command and return (exit_code, stdout, stderr)."""
    try:
        result = subprocess.run(
            cmd,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "Timeout"


def count_files(directory: Path) -> int:
    """Count files in directory recursively."""
    count = 0
    for _, _, files in os.walk(directory):
        count += len(files)
    return count


def get_dir_size_mb(directory: Path) -> float:
    """Get directory size in MB."""
    total = 0
    for entry in directory.rglob("*"):
        if entry.is_file():
            total += entry.stat().st_size
    return total / (1024 * 1024)


def print_result(result: TestResult) -> None:
    """Print test result with color."""
    status = "✅ PASS" if result.passed else "❌ FAIL"
    print(f"  {status} {result.name}")
    print(f"       Files: {result.files:,} | Time: {result.duration_sec:.2f}s | {result.message}")


# ============================================================================
# Test Cases
# ============================================================================


def test_binary_build() -> TestResult:
    """Test 1: Ensure vrift binary is built."""
    start = time.time()

    if not VRIFT_BINARY.exists():
        # Try to build
        code, _, stderr = run_cmd(
            ["cargo", "build", "--release", "-p", "vrift-cli"],
            cwd=PROJECT_ROOT,
            timeout=300,
        )
        if code != 0:
            return TestResult(
                name="Binary Build",
                passed=False,
                duration_sec=time.time() - start,
                files=0,
                message=f"Build failed: {stderr[:100]}",
            )

    # Verify binary works
    code, stdout, _ = run_cmd([str(VRIFT_BINARY), "--version"])

    return TestResult(
        name="Binary Build",
        passed=code == 0,
        duration_sec=time.time() - start,
        files=0,
        message=stdout.strip() if code == 0 else "Binary not working",
    )


def test_dataset_ingest(
    name: str, config: dict[str, Any], work_dir: Path, cas_dir: Path, is_reingest: bool = False
) -> TestResult:
    """Test: Ingest a dataset and verify."""
    start = time.time()
    test_name = f"Re-ingest {name}" if is_reingest else f"Ingest {name}"

    package_json = BENCHMARKS_DIR / config["package"]
    if not package_json.exists():
        return TestResult(
            name=test_name,
            passed=False,
            duration_sec=0,
            files=0,
            message=f"Package not found: {package_json}",
        )

    # Setup work directory
    dataset_dir = work_dir / name
    dataset_dir.mkdir(parents=True, exist_ok=True)

    node_modules = dataset_dir / "node_modules"
    install_time = 0.0

    # Skip npm install for re-ingest if node_modules exists
    if not node_modules.exists() or not is_reingest:
        shutil.copy(package_json, dataset_dir / "package.json")

        # Install dependencies
        install_start = time.time()
        code, _, stderr = run_cmd(
            ["npm", "install", "--legacy-peer-deps", "--silent"],
            cwd=dataset_dir,
            timeout=300,
        )
        if code != 0:
            # Try without legacy-peer-deps
            code, _, stderr = run_cmd(
                ["npm", "install", "--silent"],
                cwd=dataset_dir,
                timeout=300,
            )

        if code != 0:
            return TestResult(
                name=test_name,
                passed=False,
                duration_sec=time.time() - start,
                files=0,
                message=f"npm install failed: {stderr[:100]}",
            )

        install_time = time.time() - install_start

    # Count files
    file_count = count_files(node_modules)

    if file_count < config["min_files"]:
        return TestResult(
            name=test_name,
            passed=False,
            duration_sec=time.time() - start,
            files=file_count,
            message=f"Too few files: {file_count} < {config['min_files']}",
        )

    # Clear any previous vrift metadata
    vrift_meta = node_modules / ".vrift"
    if vrift_meta.exists():
        shutil.rmtree(vrift_meta)

    # Run ingest with new --the-source-root flag
    manifest_path = work_dir / f"{name}_manifest.bin"
    ingest_start = time.time()
    code, stdout, stderr = run_cmd(
        [str(VRIFT_BINARY), "--the-source-root", str(cas_dir), "ingest", str(node_modules), "-o", str(manifest_path)],
        timeout=config["max_time_sec"] * 2,
    )
    ingest_time = time.time() - ingest_start

    if code != 0:
        return TestResult(
            name=test_name,
            passed=False,
            duration_sec=time.time() - start,
            files=file_count,
            message=f"Ingest failed: {stderr[:200]}",
        )

    # Verify manifest created
    if not manifest_path.exists():
        return TestResult(
            name=test_name,
            passed=False,
            duration_sec=time.time() - start,
            files=file_count,
            message="Manifest not created",
        )

    # Check timing (re-ingest should be faster)
    max_time = config["max_time_sec"] / 2 if is_reingest else config["max_time_sec"]
    passed = ingest_time <= max_time
    rate = int(file_count / ingest_time) if ingest_time > 0 else 0

    msg_parts = [f"{rate:,} files/sec"]
    if install_time > 0:
        msg_parts.append(f"npm: {install_time:.1f}s")
    if not passed:
        msg_parts.append(f"SLOW: max {max_time:.1f}s")

    return TestResult(
        name=test_name,
        passed=passed,
        duration_sec=ingest_time,
        files=file_count,
        message=" | ".join(msg_parts),
    )


def test_dedup_efficiency(work_dir: Path, cas_dir: Path, mode: TestMode) -> TestResult:
    """Test: Cross-project deduplication."""
    start = time.time()

    # Check CAS stats
    cas_blobs = count_files(cas_dir)
    cas_size_mb = get_dir_size_mb(cas_dir)

    # Count total files in all datasets
    total_files = 0
    for name in DATASETS:
        node_modules = work_dir / name / "node_modules"
        if node_modules.exists():
            total_files += count_files(node_modules)

    if total_files == 0:
        return TestResult(
            name="Dedup Efficiency",
            passed=False,
            duration_sec=time.time() - start,
            files=0,
            message="No files ingested",
        )

    dedup_ratio = 1 - (cas_blobs / total_files) if total_files > 0 else 0

    # Different thresholds for different modes
    if mode == TestMode.ISOLATED:
        min_dedup = 0.0  # No cross-project dedup expected
    else:
        min_dedup = 0.1  # At least 10% dedup for shared mode

    passed = dedup_ratio >= min_dedup

    return TestResult(
        name="Dedup Efficiency",
        passed=passed,
        duration_sec=time.time() - start,
        files=cas_blobs,
        message=f"{total_files:,} files → {cas_blobs:,} blobs ({dedup_ratio * 100:.1f}% dedup, {cas_size_mb:.0f}MB)",
    )


def test_eperm_handling(work_dir: Path, cas_dir: Path) -> TestResult:
    """Test: EPERM handling for code-signed bundles (requires puppeteer)."""
    start = time.time()

    # Check if xlarge was ingested (contains puppeteer)
    xlarge_dir = work_dir / "xlarge" / "node_modules"
    if not xlarge_dir.exists():
        return TestResult(
            name="EPERM Handling",
            passed=True,  # Skip if xlarge not tested
            duration_sec=0,
            files=0,
            message="Skipped (xlarge not tested)",
        )

    # Look for Chromium.app
    chromium_paths = list(xlarge_dir.rglob("Chromium.app"))
    has_chromium = len(chromium_paths) > 0

    # Check if ingest succeeded (xlarge result would show success)
    manifest = work_dir / "xlarge_manifest.bin"
    ingest_succeeded = manifest.exists()

    return TestResult(
        name="EPERM Handling",
        passed=ingest_succeeded,
        duration_sec=time.time() - start,
        files=len(chromium_paths),
        message=f"Chromium.app found: {has_chromium}, Ingest: {'✓' if ingest_succeeded else '✗'}",
    )


def test_link_strategy() -> TestResult:
    """Test: LinkStrategy unit tests."""
    start = time.time()

    code, stdout, stderr = run_cmd(
        ["cargo", "test", "--package", "vrift-cas", "link_strategy", "--", "--nocapture"],
        cwd=PROJECT_ROOT,
        timeout=120,
    )

    # Parse test count
    passed_count = stdout.count("ok")

    return TestResult(
        name="LinkStrategy Tests",
        passed=code == 0,
        duration_sec=time.time() - start,
        files=0,
        message=f"{passed_count} assertions passed" if code == 0 else stderr[:100],
    )


def test_monorepo_dedup(work_dir: Path, cas_dir: Path) -> TestResult:
    """Test: True monorepo cross-package deduplication.

    Creates independent packages/ subdirectories (not npm workspaces hoisting)
    to test VRift's ability to deduplicate across separate npm installations.
    """
    start = time.time()

    monorepo_dir = work_dir / "monorepo"
    monorepo_dir.mkdir(parents=True, exist_ok=True)

    total_files = 0
    package_stats = {}

    # Create each package with its own node_modules
    pkg_count = len(MONOREPO_PACKAGES)
    for idx, (pkg_name, pkg_json) in enumerate(MONOREPO_PACKAGES.items(), 1):
        pkg_dir = monorepo_dir / "packages" / pkg_name
        pkg_dir.mkdir(parents=True, exist_ok=True)

        # Copy package.json
        src_pkg = BENCHMARKS_DIR / pkg_json
        if not src_pkg.exists():
            continue

        # Show progress
        print(f"       📦 [{idx}/{pkg_count}] Installing {pkg_name} ({pkg_json})...", flush=True)

        shutil.copy(src_pkg, pkg_dir / "package.json")

        # Install dependencies independently (NO hoisting)
        install_start = time.time()
        code, _, stderr = run_cmd(
            ["npm", "install", "--legacy-peer-deps", "--silent"],
            cwd=pkg_dir,
            timeout=300,
        )
        install_time = time.time() - install_start

        if code != 0:
            return TestResult(
                name="Monorepo Dedup",
                passed=False,
                duration_sec=time.time() - start,
                files=0,
                message=f"npm install failed for {pkg_name}: {stderr[:100]}",
            )

        # Count files
        node_modules = pkg_dir / "node_modules"
        file_count = count_files(node_modules)
        total_files += file_count
        package_stats[pkg_name] = file_count
        print(f"       ✓ {pkg_name}: {file_count:,} files ({install_time:.1f}s)", flush=True)

    if total_files == 0:
        return TestResult(
            name="Monorepo Dedup",
            passed=False,
            duration_sec=time.time() - start,
            files=0,
            message="No files installed",
        )

    # Ingest entire packages/ directory at once
    packages_dir = monorepo_dir / "packages"
    manifest_path = work_dir / "monorepo_manifest.bin"

    ingest_start = time.time()
    code, stdout, stderr = run_cmd(
        [str(VRIFT_BINARY), "--the-source-root", str(cas_dir), "ingest", str(packages_dir), "-o", str(manifest_path)],
        timeout=120,
    )
    ingest_time = time.time() - ingest_start

    if code != 0:
        return TestResult(
            name="Monorepo Dedup",
            passed=False,
            duration_sec=time.time() - start,
            files=total_files,
            message=f"Ingest failed: {stderr[:200]}",
        )

    # Check CAS blob count
    cas_blobs = count_files(cas_dir)
    dedup_ratio = 1 - (cas_blobs / total_files) if total_files > 0 else 0

    # Expect significant dedup (packages share many common deps)
    passed = dedup_ratio > 0.3  # At least 30% dedup expected

    pkg_summary = ", ".join(f"{k}={v:,}" for k, v in package_stats.items())

    return TestResult(
        name="Monorepo Dedup",
        passed=passed,
        duration_sec=ingest_time,
        files=cas_blobs,
        message=f"[{pkg_summary}] → {total_files:,} files → {cas_blobs:,} blobs ({dedup_ratio * 100:.1f}% dedup)",
    )


# ============================================================================
# Main
# ============================================================================


def main() -> None:
    # Parse arguments
    mode = TestMode.SHARED  # Default
    full_test = False
    monorepo_test = False

    for arg in sys.argv[1:]:
        if arg == "--isolated":
            mode = TestMode.ISOLATED
        elif arg == "--shared":
            mode = TestMode.SHARED
        elif arg == "--incremental":
            mode = TestMode.INCREMENTAL
        elif arg == "--full":
            full_test = True
        elif arg == "--monorepo":
            monorepo_test = True

    print("=" * 60)
    print("VRift E2E Regression Test Suite")
    print(f"Mode: {mode.value.upper()}")
    print("=" * 60)
    print()

    # Check Python version (handled by pyproject.toml)

    results: list[TestResult] = []

    # Test 1: Binary build
    print("📦 Test: Binary Build")
    result = test_binary_build()
    print_result(result)
    results.append(result)

    if not result.passed:
        print("\n❌ Cannot continue without binary")
        sys.exit(1)

    # Test 2: Unit tests
    print("\n🧪 Test: Unit Tests")
    result = test_link_strategy()
    print_result(result)
    results.append(result)

    # Determine datasets to test
    datasets_to_test = ["small", "medium"]
    if full_test:
        datasets_to_test = ["small", "medium", "large", "xlarge"]

    # Create temp directory
    tmp_dir_obj = tempfile.TemporaryDirectory(prefix="vrift-e2e-")
    try:
        tmp = tmp_dir_obj.name
        work_dir = Path(tmp) / "work"
        work_dir.mkdir()

        # Setup CAS based on mode
        if mode == TestMode.INCREMENTAL:
            cas_shared = PERSISTENT_CAS
            cas_shared.mkdir(parents=True, exist_ok=True)
            print(f"\n📁 Work dir: {work_dir}")
            print(f"📁 CAS dir: {cas_shared} (PERSISTENT)")
        else:
            cas_shared = Path(tmp) / "cas"
            cas_shared.mkdir()
            print(f"\n📁 Work dir: {work_dir}")
            print(f"📁 CAS dir: {cas_shared} (temporary)")

        if mode == TestMode.ISOLATED:
            # Each dataset gets its own CAS
            for name in datasets_to_test:
                print(f"\n📊 Test: Ingest {name.upper()} (Isolated CAS)")
                cas_isolated = Path(tmp) / f"cas_{name}"
                cas_isolated.mkdir()
                config = DATASETS[name]
                result = test_dataset_ingest(name, config, work_dir, cas_isolated)
                print_result(result)
                results.append(result)

                # Individual dedup check
                print(f"\n🔗 Test: Dedup {name}")
                result = test_dedup_efficiency(work_dir, cas_isolated, mode)
                print_result(result)
                results.append(result)

        elif mode == TestMode.SHARED:
            # All datasets share CAS
            for name in datasets_to_test:
                print(f"\n📊 Test: Ingest {name.upper()} (Shared CAS)")
                config = DATASETS[name]
                result = test_dataset_ingest(name, config, work_dir, cas_shared)
                print_result(result)
                results.append(result)

            # Cross-project dedup check
            print("\n🔗 Test: Cross-Project Dedup")
            result = test_dedup_efficiency(work_dir, cas_shared, mode)
            print_result(result)
            results.append(result)

        elif mode == TestMode.INCREMENTAL:
            # First pass: ingest
            for name in datasets_to_test:
                print(f"\n📊 Test: Initial Ingest {name.upper()}")
                config = DATASETS[name]
                result = test_dataset_ingest(name, config, work_dir, cas_shared, is_reingest=False)
                print_result(result)
                results.append(result)

            # Second pass: re-ingest (should be faster due to CAS hits)
            print("\n" + "-" * 40)
            print("🔄 Re-ingest pass (testing incremental speed)")
            print("-" * 40)

            for name in datasets_to_test:
                print(f"\n📊 Test: Re-ingest {name.upper()}")
                config = DATASETS[name]
                result = test_dataset_ingest(name, config, work_dir, cas_shared, is_reingest=True)
                print_result(result)
                results.append(result)

            # Dedup check
            print("\n🔗 Test: Dedup Efficiency")
            result = test_dedup_efficiency(work_dir, cas_shared, mode)
            print_result(result)
            results.append(result)

        # Test: EPERM handling
        if "xlarge" in datasets_to_test:
            print("\n🍎 Test: EPERM Handling (macOS)")
            result = test_eperm_handling(
                work_dir, cas_shared if mode != TestMode.ISOLATED else Path(tmp) / "cas_xlarge"
            )
            print_result(result)
            results.append(result)

        # Test: Monorepo cross-package dedup (uses separate CAS to measure properly)
        if monorepo_test:
            monorepo_cas = Path(tmp) / "cas_monorepo"
            monorepo_cas.mkdir()
            print("\n🏢 Test: Monorepo Cross-Package Dedup")
            result = test_monorepo_dedup(work_dir, monorepo_cas)
            print_result(result)
            results.append(result)
    finally:
        try:
            tmp_dir_obj.cleanup()
        except PermissionError:
            print("\n⚠️  Cleanup warning: some temporary files could not be removed (Permission Denied).")
            print("   These will be cleaned up by the system or next CI run.")

    # Summary
    print("\n" + "=" * 60)
    passed = sum(1 for r in results if r.passed)
    total = len(results)

    if passed == total:
        print(f"✅ ALL TESTS PASSED ({passed}/{total})")
        sys.exit(0)
    else:
        print(f"❌ TESTS FAILED ({passed}/{total})")
        for r in results:
            if not r.passed:
                print(f"   - {r.name}: {r.message}")
        sys.exit(1)


if __name__ == "__main__":
    main()
