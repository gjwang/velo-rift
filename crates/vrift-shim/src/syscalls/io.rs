//! FD Tracking and I/O syscall shims
//!
//! Provides file descriptor tracking for VFS files, enabling proper
//! handling of dup/dup2, fchdir, lseek, ftruncate, etc.

#[cfg(target_os = "macos")]
use crate::state::ShimGuard;
use crate::sync::RecursiveMutex;
use libc::c_int;
#[cfg(target_os = "macos")]
use libc::c_void;
#[cfg(target_os = "macos")]
use libc::off_t;
use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};

/// Global counter for open FDs to monitor saturation (RFC-0051)
pub static OPEN_FD_COUNT: AtomicUsize = AtomicUsize::new(0);

// Symbols imported from reals.rs via crate::reals
/// Global FD tracking table: fd -> (path, is_vfs_file)
static FD_TABLE: RecursiveMutex<Option<HashMap<c_int, FdEntry>>> = RecursiveMutex::new(None);

#[derive(Clone, Debug)]
pub struct FdEntry {
    pub path: String,
    pub is_vfs: bool,
}

// RFC-0051 / Pattern 2648: Using Mutex for FD_TABLE to avoid RwLock hazards during dyld bootstrap.
// Mutation (track_fd) and Read (get_fd_entry) ratio is balanced, but safety is paramount.

/// Track a new FD opened for a VFS path
pub fn track_fd(fd: c_int, path: &str, is_vfs: bool) {
    if fd < 0 {
        return;
    }

    // Pattern 2648: Allocate BEFORE acquiring lock to avoid recursing through malloc -> fstat -> FD_TABLE
    let entry = FdEntry {
        path: path.to_string(),
        is_vfs,
    };

    let mut table_guard = FD_TABLE.lock();
    if table_guard.is_none() {
        *table_guard = Some(HashMap::new());
    }
    if let Some(ref mut map) = *table_guard {
        map.insert(fd, entry);
    }
}

/// Untrack FD on close
pub fn untrack_fd(fd: c_int) {
    if fd < 0 {
        return;
    }
    let mut table = FD_TABLE.lock();
    if let Some(ref mut map) = *table {
        map.remove(&fd);
    }
}

/// Get entry for an FD
pub fn get_fd_entry(fd: c_int) -> Option<FdEntry> {
    if fd < 0 {
        return None;
    }
    let table = FD_TABLE.lock();
    if let Some(ref map) = *table {
        return map.get(&fd).cloned();
    }
    None
}

/// Check if FD is a VFS file
pub fn is_vfs_fd(fd: c_int) -> bool {
    get_fd_entry(fd).map(|e| e.is_vfs).unwrap_or(false)
}

// ============================================================================
// dup/dup2 shims - copy FD tracking on duplicate
// ============================================================================

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn dup_shim(oldfd: c_int) -> c_int {
    // BUG-007: Use raw syscall during early init OR when shim not fully ready
    // to avoid dlsym recursion and TLS pthread deadlock
    let init_state = crate::state::INITIALIZING.load(std::sync::atomic::Ordering::Relaxed);
    if init_state >= 2
        || crate::state::SHIM_STATE
            .load(std::sync::atomic::Ordering::Acquire)
            .is_null()
    {
        return crate::syscalls::macos_raw::raw_dup(oldfd);
    }

    let _guard = match ShimGuard::enter() {
        Some(g) => g,
        None => return crate::syscalls::macos_raw::raw_dup(oldfd),
    };

    let newfd = crate::syscalls::macos_raw::raw_dup(oldfd);
    if newfd >= 0 {
        // Copy tracking from oldfd to newfd
        if let Some(entry) = get_fd_entry(oldfd) {
            track_fd(newfd, &entry.path, entry.is_vfs);
        }
    }
    newfd
}

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn dup2_shim(oldfd: c_int, newfd: c_int) -> c_int {
    // BUG-007: Use raw syscall during early init OR when shim not fully ready
    // to avoid dlsym recursion and TLS pthread deadlock
    let init_state = crate::state::INITIALIZING.load(std::sync::atomic::Ordering::Relaxed);
    if init_state >= 2
        || crate::state::SHIM_STATE
            .load(std::sync::atomic::Ordering::Acquire)
            .is_null()
    {
        return crate::syscalls::macos_raw::raw_dup2(oldfd, newfd);
    }

    let _guard = match ShimGuard::enter() {
        Some(g) => g,
        None => return crate::syscalls::macos_raw::raw_dup2(oldfd, newfd),
    };

    // If newfd was tracked, untrack it (it's being replaced)
    untrack_fd(newfd);

    let result = crate::syscalls::macos_raw::raw_dup2(oldfd, newfd);
    if result >= 0 {
        // Copy tracking from oldfd to newfd
        if let Some(entry) = get_fd_entry(oldfd) {
            track_fd(result, &entry.path, entry.is_vfs);
        }
    }
    result
}

// ============================================================================
// fchdir shim - update virtual CWD from FD
// ============================================================================

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn fchdir_shim(fd: c_int) -> c_int {
    let real = std::mem::transmute::<*mut libc::c_void, unsafe extern "C" fn(c_int) -> c_int>(
        crate::reals::REAL_FCHDIR.get(),
    );

    passthrough_if_init!(real, fd);

    // If fd points to a VFS directory, we could update virtual CWD here
    // For now, just passthrough but track
    // TODO: Update virtual CWD tracking if fd is a VFS directory
    // This requires the VFS CWD infrastructure from chdir_shim

    real(fd)
}

// ============================================================================
// lseek shim - passthrough with tracking
// ============================================================================

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn lseek_shim(fd: c_int, offset: off_t, whence: c_int) -> off_t {
    let real = std::mem::transmute::<
        *mut libc::c_void,
        unsafe extern "C" fn(c_int, off_t, c_int) -> off_t,
    >(crate::reals::REAL_LSEEK.get());

    passthrough_if_init!(real, fd, offset, whence);

    // lseek works on the underlying file, which is correct for VFS
    // (VFS files are extracted to temp, so lseek on the temp file is correct)
    real(fd, offset, whence)
}

// ============================================================================
// ftruncate shim - truncate VFS file's CoW copy
// ============================================================================

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn ftruncate_shim(fd: c_int, length: off_t) -> c_int {
    let real = std::mem::transmute::<*mut libc::c_void, unsafe extern "C" fn(c_int, off_t) -> c_int>(
        crate::reals::REAL_FTRUNCATE.get(),
    );

    passthrough_if_init!(real, fd, length);

    // ftruncate works on the underlying file (CoW copy)
    // The Manifest update happens on close
    real(fd, length)
}

// ============================================================================
// close shim - untrack and trigger COW reingest
// ============================================================================

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn write_shim(
    fd: c_int,
    buf: *const c_void,
    count: libc::size_t,
) -> libc::ssize_t {
    // RFC-0051: Always use raw syscall for core I/O shims on macOS to avoid dlsym deadlocks
    crate::syscalls::macos_raw::raw_write(fd, buf, count)
}

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn read_shim(
    fd: c_int,
    buf: *mut c_void,
    count: libc::size_t,
) -> libc::ssize_t {
    // RFC-0051: Always use raw syscall for core I/O shims on macOS to avoid dlsym deadlocks
    crate::syscalls::macos_raw::raw_read(fd, buf, count)
}

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn close_shim(fd: c_int) -> c_int {
    use crate::ipc::sync_ipc_manifest_reingest;
    use crate::state::{EventType, ShimGuard, ShimState};

    // BUG-007 / RFC-0051: Use raw syscall to completely bypass libc/dlsym during critical phases.
    let init_state = crate::state::INITIALIZING.load(std::sync::atomic::Ordering::Relaxed);
    if init_state >= 2 || crate::state::CIRCUIT_TRIPPED.load(std::sync::atomic::Ordering::Relaxed) {
        return crate::syscalls::macos_raw::raw_close(fd);
    }

    let _guard = match ShimGuard::enter() {
        Some(g) => g,
        None => return crate::syscalls::macos_raw::raw_close(fd),
    };

    let state = match ShimState::get() {
        Some(s) => s,
        None => return crate::syscalls::macos_raw::raw_close(fd),
    };

    // RFC-0051: Monitor FD usage on close (to reset warning thresholds)
    let _ = crate::syscalls::io::OPEN_FD_COUNT.fetch_update(
        Ordering::Relaxed,
        Ordering::Relaxed,
        |val| Some(val.saturating_sub(1)),
    );
    state.check_fd_usage();

    // Check if this FD is a COW session
    let cow_info = {
        let mut fds = state.open_fds.lock();
        fds.remove(&fd)
    };

    // Use a hash of the FD or 0 if not tracked for general close event
    let file_id = 0; // Simplified for general close
    vfs_record!(EventType::Close, file_id, fd);

    if let Some(info) = cow_info {
        vfs_log!(
            "COW CLOSE: fd={} vpath='{}' temp='{}'",
            fd,
            info.vpath,
            info.temp_path
        );

        // Final close of the temp file before reingest
        let res = crate::syscalls::macos_raw::raw_close(fd);

        // Trigger reingest IPC
        // RFC-0047: ManifestReingest updates the CAS and Manifest
        if sync_ipc_manifest_reingest(&state.socket_path, &info.vpath, &info.temp_path) {
            vfs_record!(
                EventType::ReingestSuccess,
                vrift_ipc::fnv1a_hash(&info.vpath),
                res
            );
        } else {
            vfs_log!("REINGEST FAILED: IPC error for '{}'", info.vpath);
            vfs_record!(
                EventType::ReingestFail,
                vrift_ipc::fnv1a_hash(&info.vpath),
                -1
            );
        }

        // Note: info.temp_path is cleaned up by the daemon (zero-copy move)
        // or discarded if IPC failed (though that leaves an orphan temp file)

        res
    } else {
        // Not a COW file, but might be a VFS read-only file or non-VFS file
        untrack_fd(fd);
        crate::syscalls::macos_raw::raw_close(fd)
    }
}
