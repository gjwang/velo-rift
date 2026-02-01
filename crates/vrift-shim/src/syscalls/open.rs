#[cfg(target_os = "macos")]
use crate::interpose::*;
use crate::path::*;
use crate::state::*;
use crate::syscalls::path_ops::break_link;
use libc::{c_char, c_int, c_void, mode_t};
use std::ffi::CStr;
use std::ptr;
#[cfg(target_os = "linux")]
use std::sync::atomic::AtomicPtr;
use std::sync::atomic::Ordering;

// ============================================================================
// Open
// ============================================================================

unsafe fn open_impl(_path: *const c_char, _flags: c_int, _mode: mode_t) -> Option<c_int> {
    None
}

// ============================================================================
// Linux Shims
// ============================================================================

#[cfg(target_os = "linux")]
static REAL_OPEN: AtomicPtr<c_void> = AtomicPtr::new(ptr::null_mut());
#[cfg(target_os = "linux")]
static REAL_OPENAT: AtomicPtr<c_void> = AtomicPtr::new(ptr::null_mut());

#[cfg(target_os = "linux")]
#[no_mangle]
pub unsafe extern "C" fn open(p: *const c_char, f: c_int, m: mode_t) -> c_int {
    shim_log("[Shim] open called\n");
    let real = get_real!(REAL_OPEN, "open", OpenFn);
    open_impl(p, f, m).unwrap_or_else(|| real(p, f, m))
}

#[cfg(target_os = "linux")]
#[no_mangle]
pub unsafe extern "C" fn open64(p: *const c_char, f: c_int, m: mode_t) -> c_int {
    shim_log("[Shim] open64 called\n");
    open(p, f, m)
}

#[cfg(target_os = "linux")]
#[no_mangle]
pub unsafe extern "C" fn __open_2(p: *const c_char, f: c_int) -> c_int {
    shim_log("[Shim] __open_2 called\n");
    open(p, f, 0)
}

#[cfg(target_os = "linux")]
#[no_mangle]
pub unsafe extern "C" fn __open64_2(p: *const c_char, f: c_int) -> c_int {
    shim_log("[Shim] __open64_2 called\n");
    open(p, f, 0)
}

#[cfg(target_os = "linux")]
#[no_mangle]
pub unsafe extern "C" fn openat(dirfd: c_int, p: *const c_char, f: c_int, m: mode_t) -> c_int {
    shim_log("[Shim] openat called\n");
    let real = get_real!(REAL_OPENAT, "openat", OpenatFn);
    open_impl(p, f, m).unwrap_or_else(|| real(dirfd, p, f, m))
}

#[cfg(target_os = "linux")]
#[no_mangle]
pub unsafe extern "C" fn openat64(dirfd: c_int, p: *const c_char, f: c_int, m: mode_t) -> c_int {
    shim_log("[Shim] openat64 called\n");
    openat(dirfd, p, f, m)
}

#[cfg(target_os = "linux")]
#[no_mangle]
pub unsafe extern "C" fn __openat_2(dirfd: c_int, p: *const c_char, f: c_int) -> c_int {
    shim_log("[Shim] __openat_2 called\n");
    openat(dirfd, p, f, 0)
}

#[cfg(target_os = "linux")]
#[no_mangle]
pub unsafe extern "C" fn __openat64_2(dirfd: c_int, p: *const c_char, f: c_int) -> c_int {
    shim_log("[Shim] __openat64_2 called\n");
    openat(dirfd, p, f, 0)
}

// ============================================================================
// macOS Shims
// ============================================================================

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn open_shim(p: *const c_char, f: c_int, m: mode_t) -> c_int {
    let real = std::mem::transmute::<*const (), OpenFn>(IT_OPEN.old_func);
    // Early-boot passthrough to avoid deadlock during dyld initialization
    if INITIALIZING.load(Ordering::Relaxed) {
        return real(p, f, m);
    }
    open_impl(p, f, m).unwrap_or_else(|| real(p, f, m))
}

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn openat_shim(
    dirfd: c_int,
    pathname: *const c_char,
    flags: c_int,
    mode: mode_t,
) -> c_int {
    if INITIALIZING.load(Ordering::Relaxed) {
        let f = libc::dlsym(libc::RTLD_NEXT, c"openat".as_ptr());
        let real: OpenatFn = std::mem::transmute(f);
        return real(dirfd, pathname, flags, mode);
    }

    let _guard = match ShimGuard::enter() {
        Some(g) => g,
        None => {
            let real = std::mem::transmute::<*const (), OpenatFn>(IT_OPENAT.old_func);
            return real(dirfd, pathname, flags, mode);
        }
    };

    let real = std::mem::transmute::<*const (), OpenatFn>(IT_OPENAT.old_func);
    open_impl(pathname, flags, mode).unwrap_or_else(|| real(dirfd, pathname, flags, mode))
}

type OpenFn = unsafe extern "C" fn(*const c_char, c_int, mode_t) -> c_int;
type OpenatFn = unsafe extern "C" fn(c_int, *const c_char, c_int, mode_t) -> c_int;

#[cfg(target_os = "linux")]
unsafe fn set_errno(e: c_int) {
    *libc::__errno_location() = e;
}
#[cfg(target_os = "macos")]
unsafe fn set_errno(e: c_int) {
    *libc::__error() = e;
}
