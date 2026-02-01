use crate::interpose::*;
use crate::state::*;
use libc::{c_int, c_void, size_t, off_t};
use std::sync::atomic::Ordering;

#[no_mangle]
#[cfg(target_os = "macos")]
pub unsafe extern "C" fn mmap_shim(
    addr: *mut c_void,
    len: size_t,
    prot: c_int,
    flags: c_int,
    fd: c_int,
    offset: off_t,
) -> *mut c_void {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*mut c_void, size_t, c_int, c_int, c_int, off_t) -> *mut c_void>(IT_MMAP.old_func);
    real(addr, len, prot, flags, fd, offset)
}

#[no_mangle]
#[cfg(target_os = "macos")]
pub unsafe extern "C" fn munmap_shim(addr: *mut c_void, len: size_t) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*mut c_void, size_t) -> c_int>(IT_MUNMAP.old_func);
    real(addr, len)
}
