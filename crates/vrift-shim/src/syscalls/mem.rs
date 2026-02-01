use crate::interpose::*;
use libc::{c_int, c_void, size_t};

#[no_mangle]
#[cfg(target_os = "macos")]
pub unsafe extern "C" fn mlock_shim(addr: *const c_void, len: size_t) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_void, size_t) -> c_int>(IT_MLOCK.old_func);
    real(addr, len)
}

#[no_mangle]
#[cfg(target_os = "macos")]
pub unsafe extern "C" fn munlock_shim(addr: *const c_void, len: size_t) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_void, size_t) -> c_int>(IT_MUNLOCK.old_func);
    real(addr, len)
}
