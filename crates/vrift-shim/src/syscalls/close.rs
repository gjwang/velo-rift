use crate::interpose::*;
use libc::c_int;

#[no_mangle]
#[cfg(target_os = "macos")]
pub unsafe extern "C" fn close_shim(fd: c_int) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(c_int) -> c_int>(IT_CLOSE.old_func);
    real(fd)
}
