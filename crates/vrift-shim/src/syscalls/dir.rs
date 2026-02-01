use crate::interpose::*;
use crate::state::*;
use libc::{c_int, c_void};

#[no_mangle]
#[cfg(target_os = "macos")]
pub unsafe extern "C" fn opendir_shim(path: *const libc::c_char) -> *mut c_void {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const libc::c_char) -> *mut c_void>(IT_OPENDIR.old_func);
    real(path)
}

#[no_mangle]
#[cfg(target_os = "macos")]
pub unsafe extern "C" fn readdir_shim(dir: *mut c_void) -> *mut libc::dirent {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*mut c_void) -> *mut libc::dirent>(IT_READDIR.old_func);
    real(dir)
}

#[no_mangle]
#[cfg(target_os = "macos")]
pub unsafe extern "C" fn closedir_shim(dir: *mut c_void) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*mut c_void) -> c_int>(IT_CLOSEDIR.old_func);
    real(dir)
}

#[no_mangle]
#[cfg(target_os = "macos")]
pub unsafe extern "C" fn getcwd_shim(buf: *mut libc::c_char, size: libc::size_t) -> *mut libc::c_char {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*mut libc::c_char, libc::size_t) -> *mut libc::c_char>(IT_GETCWD.old_func);
    real(buf, size)
}
