# Build Acceleration Scenarios: Deep Alignment (RFC-0039/RFC-0043)

This document focuses on the core use case for Velo Rift™: accelerating large-scale builds (Node.js, Rust/Cargo, C/C++). It defines critical behavior requirements that must be verified to ensure "Transparent Projection" doesn't break developer workflows.

## 1. Node.js Scenario: Massive Symlink & Metascan

**Context**: A typical `node_modules` directory contains thousands of tiny files and many symlinks (especially with `pnpm` or `yarn berry`).

| Test Case | ID | Criterion | Implementation Focus |
|-----------|----|-----------|----------------------|
| **Symlink Resolution** | B1 | The Shim must correctly resolve symlinks within the virtual projection even if targets are outside the current prefix. | `open_impl` and `stat` interception. |
| **Recursive Scan Speed** | B2 | Ingesting a 10k+ node_modules directory should be O(N) and not bottlenecked by IPC handshakes. | Proactive batching in `vrift-cli`. |
| **Lifecycle Hooks** | B3 | `npm postinstall` scripts often modify files. BBW must be fast enough to avoid script timeouts. | Zero-copy CoW mechanism. |
| **stat Interception** | B3.1 | **[CRITICAL FAIL]** Shim does not intercept `stat`. Build tools cannot "see" projected files. | Verified: `test_mtime_integrity.sh`. |

---

## 2. Rust/Cargo Scenario: Incremental Fingerprinting

**Context**: Cargo relies heavily on `mtime` (modified time) to determine if a crate needs re-compilation.

| Test Case | ID | Criterion | Implementation Focus |
|-----------|----|-----------|----------------------|
| **mtime Preservation** | B4 | **[PASS]** Ingesting a file into CAS MUST preserve its source `mtime`. | Verified: `test_mtime_integrity.sh`. |
| **Fingerprint Stability** | B5 | **[FAIL]** Building on projected sources. | Depends on B3.1. |
| **Linker Atomicity** | B6 | The Rust linker (`rustc`) uses atomic `rename`. The Shim must intercept `rename` to perform CoW on the target or allow valid moves. | `rename` interception in `vrift-shim`. |

---

## 3. C/C++ Build Scenario: Deterministic Timestamp Chains

**Context**: `make` and `ninja` calculate build graphs based on the "newness" of dependencies.

| Test Case | ID | Criterion | Implementation Focus |
|-----------|----|-----------|----------------------|
| **Build Graph Integrity** | B7 | Projected headers (.h) must have timestamps OLDER than projected objects (.o) if that was the state during ingestion. | Global timestamp normalization vs. preservation. |
| **Search Path (`-I`)** | B8 | Compiler search paths using projected directories must behave identically to local directories. | Shim `readdir` and `stat`. |

---

## 4. Multi-Tenant Build Cache (CI/CD)

**Context**: Multiple CI jobs sharing a global CAS on the same runner.

| Test Case | ID | Criterion | Implementation Focus |
|-----------|----|-----------|----------------------|
| **Cache Warm-up** | B9 | User B should benefit from User A's ingest immediately. | `CasInsert` real-time sync via Daemon. |
| **Action Privacy** | B10 | User A's build logs/manifests should be invisible to User B even if they share the same `vriftd`. | UID-based manifest isolation. |

---

## Required POC Tooling

1. **`test_mtime_integrity.rs`**: A tool to assert that metadata remains identical after ingest/projection.
2. **`test_parallel_build_simulator.sh`**: Simulates multiple parallel `write` and `rename` operations to test Shim locking.
3. **`test_npm_pnpm_layout.sh`**: Specific test for the complex symlink structures used by modern Node.js package managers.
