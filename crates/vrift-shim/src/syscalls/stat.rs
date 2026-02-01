use crate::interpose::*;
use crate::state::*;
use libc::{c_char, c_int, stat};
use std::ffi::CStr;
use std::sync::atomic::Ordering;

/// RFC-0044: Virtual stat implementation using Hot Stat Cache
/// Returns None to fallback to OS, Some(0) on success, Some(-1) on error
unsafe fn stat_impl(path: *const c_char, buf: *mut stat) -> Option<c_int> {
    if path.is_null() || buf.is_null() {
        return None;
    }

    let _guard = ShimGuard::enter()?;
    let state = ShimState::get()?;

    let path_str = CStr::from_ptr(path).to_str().ok()?;

    // Check if in VFS domain (O(1) prefix check)
    if !state.psfs_applicable(path_str) {
        return None;
    }

    // Try Hot Stat Cache (O(1) mmap lookup)
    if let Some(entry) = mmap_lookup(state.mmap_ptr, state.mmap_size, path_str) {
        // Populate stat buffer with virtual metadata
        std::ptr::write_bytes(buf, 0, 1);
        (*buf).st_size = entry.size as i64;
        (*buf).st_mode = entry.mode as u16;
        (*buf).st_mtime = entry.mtime;
        // RFC-0049: LOGOS! device ID for VFS files
        (*buf).st_dev = 0x56524654; // "VRFT" - VRift device ID
        (*buf).st_nlink = 1;
        (*buf).st_ino = vrift_ipc::fnv1a_hash(path_str);
        (*buf).st_ino = vrift_ipc::fnv1a_hash(path_str);
        return Some(0);
    }

    // Fall back to IPC query
    if let Some(entry) = state.query_manifest(path_str) {
        std::ptr::write_bytes(buf, 0, 1);
        (*buf).st_size = entry.size as i64;
        (*buf).st_mode = entry.mode as u16;
        (*buf).st_mtime = entry.mtime as i64;
        (*buf).st_dev = 0x56524654; // VRFT device ID
        (*buf).st_nlink = 1;
        (*buf).st_ino = vrift_ipc::fnv1a_hash(path_str);
        return Some(0);
    }

    None // Fallback to real stat
}

#[no_mangle]
#[cfg(target_os = "linux")]
pub unsafe extern "C" fn stat(path: *const c_char, buf: *mut stat) -> c_int {
    let real = libc::dlsym(libc::RTLD_NEXT, c"stat".as_ptr())
        as unsafe extern "C" fn(*const c_char, *mut stat) -> c_int;
    stat_impl(path, buf).unwrap_or_else(|| real(path, buf))
}

#[no_mangle]
#[cfg(target_os = "macos")]
pub unsafe extern "C" fn stat_shim(path: *const c_char, buf: *mut stat) -> c_int {
    let real = std::mem::transmute::<
        *const (),
        unsafe extern "C" fn(*const c_char, *mut stat) -> c_int,
    >(IT_STAT.old_func);
    if INITIALIZING.load(Ordering::Relaxed) {
        return real(path, buf);
    }
    stat_impl(path, buf).unwrap_or_else(|| real(path, buf))
}

#[no_mangle]
#[cfg(target_os = "macos")]
pub unsafe extern "C" fn lstat_shim(path: *const c_char, buf: *mut stat) -> c_int {
    let real = std::mem::transmute::<
        *const (),
        unsafe extern "C" fn(*const c_char, *mut stat) -> c_int,
    >(IT_LSTAT.old_func);
    if INITIALIZING.load(Ordering::Relaxed) {
        return real(path, buf);
    }
    // lstat uses same logic as stat for VFS (no symlinks in manifest)
    stat_impl(path, buf).unwrap_or_else(|| real(path, buf))
}

#[no_mangle]
#[cfg(target_os = "macos")]
pub unsafe extern "C" fn fstat_shim(fd: c_int, buf: *mut stat) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(c_int, *mut stat) -> c_int>(
        IT_FSTAT.old_func,
    );
    if INITIALIZING.load(Ordering::Relaxed) {
        return real(fd, buf);
    }

    // Check if fd is tracked in open_fds
    let _guard = match ShimGuard::enter() {
        Some(g) => g,
        None => return real(fd, buf),
    };

    let state = match ShimState::get() {
        Some(s) => s,
        None => return real(fd, buf),
    };

    let vpath = {
        let fds = state.open_fds.lock().ok();
        fds.and_then(|f| f.get(&fd).map(|of| of.vpath.clone()))
    };

    if let Some(path_str) = vpath {
        if let Some(entry) = mmap_lookup(state.mmap_ptr, state.mmap_size, &path_str) {
            std::ptr::write_bytes(buf, 0, 1);
            (*buf).st_size = entry.size as i64;
            (*buf).st_mode = entry.mode as u16;
            (*buf).st_mtime = entry.mtime;
            (*buf).st_dev = 0x56524654; // VRFT
            (*buf).st_nlink = 1;
            (*buf).st_ino = vrift_ipc::fnv1a_hash(&path_str);
            return 0;
        }
        if let Some(entry) = state.query_manifest(&path_str) {
            std::ptr::write_bytes(buf, 0, 1);
            (*buf).st_size = entry.size as i64;
            (*buf).st_mode = entry.mode as u16;
            (*buf).st_mtime = entry.mtime as i64;
            (*buf).st_dev = 0x56524654; // VRFT
            (*buf).st_nlink = 1;
            (*buf).st_ino = vrift_ipc::fnv1a_hash(&path_str);
            return 0;
        }
    }

    real(fd, buf)
}
