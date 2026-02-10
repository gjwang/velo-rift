//! Build Cache — mtime override for target artifacts (POC).
//!
//! Intercepts stat() calls for build artifacts under target/ and overrides
//! their mtime to a uniform timestamp. This tricks build systems (cargo, make, etc.)
//! into seeing "all outputs are newer than all sources" → no-op build.
//!
//! This is a **POC shim** — the production implementation will use VDir to serve
//! target/ artifacts with their original build-time mtimes, making this module
//! unnecessary.

pub mod cargo;

use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};

// ── Build Cache State (process-global, lock-free) ──

/// Whether build cache mtime override is active.
static ACTIVE: AtomicBool = AtomicBool::new(false);

/// The uniform mtime (epoch seconds) to return for all target artifacts.
/// Set to `now()` when build cache is enabled.
static OVERRIDE_MTIME: AtomicI64 = AtomicI64::new(0);

/// Count of mtime overrides applied (diagnostics).
pub static OVERRIDE_COUNT: AtomicU64 = AtomicU64::new(0);
/// Count of times should_override_mtime was called (diagnostics).
pub static CHECK_COUNT: AtomicU64 = AtomicU64::new(0);

/// Enable build cache mtime override.
///
/// All target artifacts will have their stat() mtime overridden to
/// `mtime_override` (typically `now()`).
pub fn activate(mtime_override: i64) {
    OVERRIDE_MTIME.store(mtime_override, Ordering::Release);
    ACTIVE.store(true, Ordering::Release);
}

/// Disable build cache mtime override.
pub fn invalidate() {
    ACTIVE.store(false, Ordering::Release);
    OVERRIDE_MTIME.store(0, Ordering::Release);
}

/// Check if a path should have its mtime overridden.
///
/// Called from `stat_impl` on every stat in the fallback path.
/// Returns `Some(mtime)` if the path is a target artifact and
/// the override is active, `None` otherwise.
#[inline]
pub fn should_override_mtime(path: &str) -> Option<i64> {
    if !ACTIVE.load(Ordering::Relaxed) {
        return None;
    }

    CHECK_COUNT.fetch_add(1, Ordering::Relaxed);

    if cargo::is_target_artifact(path) {
        let ts = OVERRIDE_MTIME.load(Ordering::Relaxed);
        if ts > 0 {
            OVERRIDE_COUNT.fetch_add(1, Ordering::Relaxed);
            return Some(ts);
        }
    }

    None
}

/// Check if build cache mtime override is currently active.
pub fn is_active() -> bool {
    ACTIVE.load(Ordering::Relaxed)
}
