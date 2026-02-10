//! Cargo Build Cache Wrapper
//!
//! Cargo-specific logic for the build cache system.
//!
//! Cargo determines "needs recompile?" by multiple mtime comparisons:
//!   1. source_file.mtime vs dep-info.mtime (in .fingerprint/)
//!   2. output.mtime vs dep_output.mtime (in deps/, build/)
//!
//! ALL target artifacts need consistent mtime=now() to satisfy both checks.
//!
//! This wrapper:
//! 1. Detects ALL files under target/ directories
//! 2. Overrides their mtime to `now()` when build cache is active
//! 3. Cargo sees "all artifacts are newer than all sources" → no-op
//!
//! Result: cargo sees "just compiled" → no-op → 240ms (vs 51s baseline).

/// Check if a path is a cargo target artifact.
///
/// Matches ANY file under a `target/` directory, including:
/// - .fingerprint/ (dep-info, invoked.timestamp)
/// - deps/ (.rlib, .rmeta, .d files)
/// - build/ (build script outputs)
/// - incremental/ (incremental compilation cache)
///
/// This is called on every stat, so it must be very fast.
#[inline]
pub fn is_target_artifact(path: &str) -> bool {
    // Quick length check
    if path.len() < 10 {
        return false;
    }

    // Check for /target/debug/ or /target/release/ pattern
    path.contains("/target/debug/") || path.contains("/target/release/")
}

/// Initialize the cargo build cache.
///
/// Called during InceptionLayerState init when `VRIFT_BUILD_CACHE=1` is set.
/// Activates mtime override with current timestamp.
pub fn init_if_enabled() {
    // Check environment variable
    let env_ptr = unsafe { libc::getenv(c"VRIFT_BUILD_CACHE".as_ptr()) };
    if env_ptr.is_null() {
        return;
    }

    let val = unsafe { std::ffi::CStr::from_ptr(env_ptr) };
    if val.to_bytes() != b"1" {
        return;
    }

    // Get current time as epoch seconds for mtime override
    let mut tv = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };

    #[cfg(target_os = "macos")]
    unsafe {
        libc::clock_gettime(libc::CLOCK_REALTIME, &mut tv);
    }

    #[cfg(target_os = "linux")]
    unsafe {
        libc::clock_gettime(libc::CLOCK_REALTIME, &mut tv);
    }

    let now_sec = tv.tv_sec;

    if now_sec > 0 {
        super::activate(now_sec);

        // Log activation (using inception_log! equivalent)
        #[cfg(debug_assertions)]
        {
            let _ = std::io::Write::write_fmt(
                &mut std::io::stderr(),
                format_args!(
                    "[vrift-build-cache] Cargo wrapper activated, mtime override = {}\n",
                    now_sec
                ),
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_target_artifact() {
        // Positive cases — all files under target/debug/ or target/release/
        assert!(is_target_artifact(
            "/target/debug/.fingerprint/serde-abc123/invoked.timestamp"
        ));
        assert!(is_target_artifact(
            "/target/release/.fingerprint/my-crate-def456/dep-lib-my_crate"
        ));
        assert!(is_target_artifact("/target/debug/deps/libserde.rlib"));
        assert!(is_target_artifact("/target/release/deps/libserde.rmeta"));
        assert!(is_target_artifact(
            "/target/debug/build/velo-core-abc123/output"
        ));
        assert!(is_target_artifact(
            "/target/debug/incremental/velo-12345/s-abc-xyz/query-cache.bin"
        ));

        // Negative cases
        assert!(!is_target_artifact("/src/main.rs"));
        assert!(!is_target_artifact("/target/config.toml")); // not under debug/ or release/
        assert!(!is_target_artifact("")); // empty
        assert!(!is_target_artifact("short")); // too short
    }
}
