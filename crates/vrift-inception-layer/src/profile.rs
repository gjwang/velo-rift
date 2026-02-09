//! RFC-0045: VFS Performance Profiling — Phase 1 Core Counters
//!
//! Zero-overhead when disabled (VRIFT_PROFILE unset).
//! When enabled (VRIFT_PROFILE=1), increments global AtomicU64 counters
//! on each interposed syscall. On process exit (atexit), writes JSON
//! to `/tmp/vrift-profile-<pid>.json` for `vrift profile show`.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

/// Master enable flag — checked by profile_count! macro.
/// Set to true during init if VRIFT_PROFILE=1.
pub static PROFILE_ENABLED: AtomicBool = AtomicBool::new(false);

/// Global profile counters — always present in .bss, zero cost when disabled.
pub static PROFILE: VriftProfile = VriftProfile::new();

/// RFC-0045 §61-113: Performance profile counters
#[repr(C)]
pub struct VriftProfile {
    // ── Syscall Counters ──
    pub stat_calls: AtomicU64,
    pub fstat_calls: AtomicU64,
    pub lstat_calls: AtomicU64,
    pub open_calls: AtomicU64,
    pub close_calls: AtomicU64,
    pub read_calls: AtomicU64,
    pub write_calls: AtomicU64,
    pub readdir_calls: AtomicU64,
    pub access_calls: AtomicU64,

    // ── VFS Contribution ──
    pub vfs_handled: AtomicU64,     // Syscalls fully resolved by VFS
    pub vfs_passthrough: AtomicU64, // Syscalls passed to real FS

    // ── Cache Stats ──
    pub vdir_hits: AtomicU64,   // VDir mmap hit
    pub vdir_misses: AtomicU64, // VDir miss → IPC fallback
    pub ipc_calls: AtomicU64,   // IPC roundtrips to daemon

    // ── Timestamp ──
    pub start_time_ns: AtomicU64,
}

// Safety: All fields are AtomicU64/AtomicBool — inherently Sync.
unsafe impl Sync for VriftProfile {}

impl VriftProfile {
    pub const fn new() -> Self {
        Self {
            stat_calls: AtomicU64::new(0),
            fstat_calls: AtomicU64::new(0),
            lstat_calls: AtomicU64::new(0),
            open_calls: AtomicU64::new(0),
            close_calls: AtomicU64::new(0),
            read_calls: AtomicU64::new(0),
            write_calls: AtomicU64::new(0),
            readdir_calls: AtomicU64::new(0),
            access_calls: AtomicU64::new(0),
            vfs_handled: AtomicU64::new(0),
            vfs_passthrough: AtomicU64::new(0),
            vdir_hits: AtomicU64::new(0),
            vdir_misses: AtomicU64::new(0),
            ipc_calls: AtomicU64::new(0),
            start_time_ns: AtomicU64::new(0),
        }
    }
}

impl Default for VriftProfile {
    fn default() -> Self {
        Self::new()
    }
}

/// Increment a profile counter if profiling is enabled.
/// Compiles to a single atomic branch + fetch_add on hot path.
#[macro_export]
macro_rules! profile_count {
    ($field:ident) => {
        if $crate::profile::PROFILE_ENABLED.load(std::sync::atomic::Ordering::Relaxed) {
            $crate::profile::PROFILE
                .$field
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        }
    };
}

/// Initialize profiling: check VRIFT_PROFILE env var, record start time.
/// Called from InceptionLayerState::init() after env is safe to read.
pub fn init_profile() {
    // Read env var — safe because this runs after dyld bootstrap
    let enabled = std::env::var("VRIFT_PROFILE")
        .map(|v| v == "1" || v.to_lowercase() == "true")
        .unwrap_or(false);

    if !enabled {
        return;
    }

    PROFILE_ENABLED.store(true, Ordering::Release);

    // Record session start time
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64;
    PROFILE.start_time_ns.store(now, Ordering::Relaxed);

    // Register atexit handler to dump profile on normal exit
    unsafe {
        libc::atexit(profile_atexit_handler);
    }
}

/// atexit handler — writes profile JSON to /tmp/vrift-profile-<pid>.json
extern "C" fn profile_atexit_handler() {
    if !PROFILE_ENABLED.load(Ordering::Relaxed) {
        return;
    }
    dump_profile_json();
}

/// Write profile data as JSON to /tmp/vrift-profile-<pid>.json
fn dump_profile_json() {
    use std::fmt::Write;

    let pid = unsafe { libc::getpid() };

    // Snapshot all counters (Relaxed is fine — atexit is single-threaded)
    let stat = PROFILE.stat_calls.load(Ordering::Relaxed);
    let fstat = PROFILE.fstat_calls.load(Ordering::Relaxed);
    let lstat = PROFILE.lstat_calls.load(Ordering::Relaxed);
    let open = PROFILE.open_calls.load(Ordering::Relaxed);
    let close = PROFILE.close_calls.load(Ordering::Relaxed);
    let read = PROFILE.read_calls.load(Ordering::Relaxed);
    let write_c = PROFILE.write_calls.load(Ordering::Relaxed);
    let readdir = PROFILE.readdir_calls.load(Ordering::Relaxed);
    let access = PROFILE.access_calls.load(Ordering::Relaxed);
    let handled = PROFILE.vfs_handled.load(Ordering::Relaxed);
    let passthrough = PROFILE.vfs_passthrough.load(Ordering::Relaxed);
    let vdir_hit = PROFILE.vdir_hits.load(Ordering::Relaxed);
    let vdir_miss = PROFILE.vdir_misses.load(Ordering::Relaxed);
    let ipc = PROFILE.ipc_calls.load(Ordering::Relaxed);
    let start = PROFILE.start_time_ns.load(Ordering::Relaxed);

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64;
    let duration_ns = now.saturating_sub(start);
    let duration_ms = duration_ns / 1_000_000;

    let total_calls = stat + fstat + lstat + open + close + read + write_c + readdir + access;

    let mut buf = String::with_capacity(2048);
    let _ = writeln!(buf, "{{");
    let _ = writeln!(buf, "  \"pid\": {},", pid);
    let _ = writeln!(buf, "  \"duration_ms\": {},", duration_ms);
    let _ = writeln!(buf, "  \"total_syscalls\": {},", total_calls);
    let _ = writeln!(buf, "  \"syscalls\": {{");
    let _ = writeln!(buf, "    \"stat\": {},", stat);
    let _ = writeln!(buf, "    \"fstat\": {},", fstat);
    let _ = writeln!(buf, "    \"lstat\": {},", lstat);
    let _ = writeln!(buf, "    \"open\": {},", open);
    let _ = writeln!(buf, "    \"close\": {},", close);
    let _ = writeln!(buf, "    \"read\": {},", read);
    let _ = writeln!(buf, "    \"write\": {},", write_c);
    let _ = writeln!(buf, "    \"readdir\": {},", readdir);
    let _ = writeln!(buf, "    \"access\": {}", access);
    let _ = writeln!(buf, "  }},");
    let _ = writeln!(buf, "  \"vfs\": {{");
    let _ = writeln!(buf, "    \"handled\": {},", handled);
    let _ = writeln!(buf, "    \"passthrough\": {},", passthrough);
    if handled + passthrough > 0 {
        let pct = 100.0 * handled as f64 / (handled + passthrough) as f64;
        let _ = writeln!(buf, "    \"handled_pct\": {:.1}", pct);
    } else {
        let _ = writeln!(buf, "    \"handled_pct\": 0.0");
    }
    let _ = writeln!(buf, "  }},");
    let _ = writeln!(buf, "  \"cache\": {{");
    let _ = writeln!(buf, "    \"vdir_hits\": {},", vdir_hit);
    let _ = writeln!(buf, "    \"vdir_misses\": {},", vdir_miss);
    if vdir_hit + vdir_miss > 0 {
        let pct = 100.0 * vdir_hit as f64 / (vdir_hit + vdir_miss) as f64;
        let _ = writeln!(buf, "    \"hit_rate_pct\": {:.1},", pct);
    } else {
        let _ = writeln!(buf, "    \"hit_rate_pct\": 0.0,");
    }
    let _ = writeln!(buf, "    \"ipc_calls\": {}", ipc);
    let _ = writeln!(buf, "  }}");
    let _ = write!(buf, "}}");

    // Write to file — use raw libc to avoid allocator issues in atexit
    let path = format!("/tmp/vrift-profile-{}.json\0", pid);
    unsafe {
        let fd = libc::open(
            path.as_ptr() as *const libc::c_char,
            libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC,
            0o644,
        );
        if fd >= 0 {
            libc::write(fd, buf.as_ptr() as *const libc::c_void, buf.len());
            libc::close(fd);
        }
    }

    // Also print summary to stderr for immediate feedback
    let summary = format!(
        "\n[vrift-profile] PID {} | {:.1}s | {} syscalls | VFS {}/{} ({:.0}%) | VDir hit {:.0}% | wrote {}\n",
        pid,
        duration_ms as f64 / 1000.0,
        total_calls,
        handled,
        handled + passthrough,
        if handled + passthrough > 0 { 100.0 * handled as f64 / (handled + passthrough) as f64 } else { 0.0 },
        if vdir_hit + vdir_miss > 0 { 100.0 * vdir_hit as f64 / (vdir_hit + vdir_miss) as f64 } else { 0.0 },
        &path[..path.len() - 1], // strip null
    );
    unsafe {
        libc::write(2, summary.as_ptr() as *const libc::c_void, summary.len());
    }
}
