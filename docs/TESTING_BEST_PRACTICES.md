# Velo Rift™ Testing Best Practices: Simulation vs. Production

This document outlines the architectural boundaries between **Production Logic** and **Simulation Hooks** to ensure Velo Rift remains industrial-grade and performance-optimized.

---

## 🏗️ 1. The Clean Logic Principle
**Simulation code must NEVER change the critical path of production business logic.** 

### ❌ Anti-Pattern: Ad-hoc Hooks
```rust
// crates/vrift-shim/src/lib.rs
if std::env::var("LEAK_FD").is_ok() {
    leak_socket(); // Modifies binary size and branch prediction in production
}
```

### ✅ Best Practice: Feature-Gated Hooks
Use Rust feature flags to ensure simulation code is physically removed from the production artifact.

```rust
#[cfg(feature = "test-hooks")]
{
    if std::env::var("VRIFT_SIMULATE_LEAK").is_ok() {
        self.leak_canary_socket();
    }
}
```
*Run tests with: `cargo test --features test-hooks`*

---

## 🧪 2. Multi-Tier Verification Strategy

| Tier | Name | Purpose | Implementation |
| :--- | :--- | :--- | :--- |
| **Tier 1** | **Forensic Proofs** | Temporary proofs of concept for specific vulnerabilities. | Out-of-tree C/Rust POCs (e.g., `mock_leak_shim`). |
| **Tier 2** | **Behavioral E2E** | Verifying logic under real conditions. | Black-box tests using `lsof`, `strace`, and `nm`. |
| **Tier 3** | **Shim Invariants** | Hardening common pitfalls (like `O_CLOEXEC`). | **Wrapper Enforcements** (see below). |

---

## 🛡️ 3. Hardening: "Correct by Design"
Instead of simulating failures, use wrappers that make the error impossible.

### Example: O_CLOEXEC Enforcement
Don't call `libc::socket` directly. Use a Velo-specific raw wrapper:

```rust
unsafe fn raw_unix_connect_safe(path: &str) -> c_int {
    let fd = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0);
    if fd >= 0 {
        // Enforce CLOEXEC immediately
        libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
    }
    fd
}
```

---

## 🔬 4. Mocking the System, Not the Shim
When testing a "Leak," the best practice is to **Mock the Environment** rather than modifying the Shim's source:

1.  **LD_PRELOAD Chaining**: Use a secondary "Test Shim" that sits on top of the real Shim to manipulate inputs/state.
2.  **LSOF Assertion**: In CI, always run process tree audits to verify FD counts remain stable after `execve`.

---

- **Forensic POCs**: Use them to find bugs, but don't commit them to the main `init` path.

---

## 🗄️ 5. Repository Structure: Where to Commit?

To keep the repository clean while ensuring 100% test coverage, follow this directory structure:

### `/tests/poc/` (Proof of Concept)
- **Status**: Experimental / Diagnostic.
- **Goal**: One-off scripts to confirm a bug or explore a behavior.
- **CI**: Not automatically run. Manual execution for developers.
- **Retention**: Deleted once the logic is promoted to `/tests/regression/`.

### `/tests/regression/` (Proof of Failure/Success)
- **Status**: Standardized / Permanent.
- **Goal**: Deterministic tests that MUST pass.
- **Implementation**: Shell scripts (for black-box) or Rust `#[test]` (for white-box).
- **CI**: Part of the **Tier 2 (Functional)** CI suite.

---

## 🤖 6. CI Integration: Tiered Execution

Velo Rift uses a **Tiered CI Model** to balance speed and coverage.

1.  **Tier 1: Build & Unit** (`cargo test`)
    -   Runs on every pull request.
    -   Must complete in < 2 minutes.
2.  **Tier 2: Functional (Regression)** (`tests/regression/*`)
    -   Tests specific P0 gaps (like FD Leakage, Normalization Bypass).
    -   Uses standardized environments (e.g., Docker ARM64 Linux).
3.  **Tier 3: E2E (Simulation)**
    -   Full compiler toolchain tests (Clang/GCC builds).
    -   Expensive; runs on `main` merge or nightly.

> [!TIP]
> **Deterministic Regression**: When a bug is found (e.g., FD Leak), create a `tests/regression/test_xxx.sh`. This script should fail initially (PoF) and pass once the fix is applied. Committing the PoF ensures the bug **never returns**.

---

## 🏁 Summary
- **Keep Production Pure**: No `if test` in the hot path. Use feature flags for hooks.
- **Categorize Appropriately**: POCs for discovery, Regression for the long-term.
- **Automate Failures**: Commit tests that *prove* a failure to prevent regressions.
