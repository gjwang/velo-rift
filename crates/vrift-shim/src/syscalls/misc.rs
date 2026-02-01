use crate::interpose::*;
use crate::state::*;
use libc::{c_char, c_int, mode_t, size_t, ssize_t, c_void};
use std::ffi::CStr;
use std::sync::atomic::Ordering;

// RFC-0049: Minimal stubs for build testing. 
// These will be incrementally replaced with real logic once linkage is verified.

#[no_mangle]
pub unsafe extern "C" fn open_shim(p: *const c_char, f: c_int, m: mode_t) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_char, c_int, mode_t) -> c_int>(IT_OPEN.old_func);
    if INITIALIZING.load(Ordering::Relaxed) {
        return real(p, f, m);
    }
    real(p, f, m)
}

#[no_mangle]
pub unsafe extern "C" fn openat_shim(dirfd: c_int, p: *const c_char, f: c_int, m: mode_t) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(c_int, *const c_char, c_int, mode_t) -> c_int>(IT_OPENAT.old_func);
    real(dirfd, p, f, m)
}

#[no_mangle]
pub unsafe extern "C" fn close_shim(fd: c_int) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(c_int) -> c_int>(IT_CLOSE.old_func);
    real(fd)
}

#[no_mangle]
pub unsafe extern "C" fn write_shim(fd: c_int, buf: *const c_void, count: size_t) -> ssize_t {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(c_int, *const c_void, size_t) -> ssize_t>(IT_WRITE.old_func);
    real(fd, buf, count)
}

#[no_mangle]
pub unsafe extern "C" fn read_shim(fd: c_int, buf: *mut c_void, count: size_t) -> ssize_t {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(c_int, *mut c_void, size_t) -> ssize_t>(IT_READ.old_func);
    real(fd, buf, count)
}

#[no_mangle]
pub unsafe extern "C" fn stat_shim(path: *const c_char, buf: *mut libc::stat) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_char, *mut libc::stat) -> c_int>(IT_STAT.old_func);
    real(path, buf)
}

#[no_mangle]
pub unsafe extern "C" fn lstat_shim(path: *const c_char, buf: *mut libc::stat) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_char, *mut libc::stat) -> c_int>(IT_LSTAT.old_func);
    real(path, buf)
}

#[no_mangle]
pub unsafe extern "C" fn fstat_shim(fd: c_int, buf: *mut libc::stat) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(c_int, *mut libc::stat) -> c_int>(IT_FSTAT.old_func);
    real(fd, buf)
}

#[no_mangle]
pub unsafe extern "C" fn opendir_shim(path: *const c_char) -> *mut c_void {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_char) -> *mut c_void>(IT_OPENDIR.old_func);
    real(path)
}

#[no_mangle]
pub unsafe extern "C" fn readdir_shim(dir: *mut c_void) -> *mut libc::dirent {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*mut c_void) -> *mut libc::dirent>(IT_READDIR.old_func);
    real(dir)
}

#[no_mangle]
pub unsafe extern "C" fn closedir_shim(dir: *mut c_void) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*mut c_void) -> c_int>(IT_CLOSEDIR.old_func);
    real(dir)
}

#[no_mangle]
pub unsafe extern "C" fn getcwd_shim(buf: *mut c_char, size: size_t) -> *mut c_char {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*mut c_char, size_t) -> *mut c_char>(IT_GETCWD.old_func);
    real(buf, size)
}

#[no_mangle]
pub unsafe extern "C" fn chdir_shim(path: *const c_char) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_char) -> c_int>(IT_CHDIR.old_func);
    real(path)
}

#[no_mangle]
pub unsafe extern "C" fn unlink_shim(path: *const c_char) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_char) -> c_int>(IT_UNLINK.old_func);
    real(path)
}

/// RFC-0047: Rename implementation with VFS boundary enforcement
/// Returns EXDEV (18) for cross-domain renames
unsafe fn rename_impl(old: *const c_char, new: *const c_char) -> Option<c_int> {
    if old.is_null() || new.is_null() {
        return None;
    }

    let _guard = ShimGuard::enter()?;
    let state = ShimState::get()?;
    
    let old_str = CStr::from_ptr(old).to_str().ok()?;
    let new_str = CStr::from_ptr(new).to_str().ok()?;
    
    let old_in_vfs = state.psfs_applicable(old_str);
    let new_in_vfs = state.psfs_applicable(new_str);
    
    // RFC-0047: Cross-boundary rename is forbidden
    if old_in_vfs != new_in_vfs {
        // Set errno to EXDEV
        #[cfg(target_os = "macos")]
        { *libc::__error() = libc::EXDEV; }
        #[cfg(target_os = "linux")]
        { *libc::__errno_location() = libc::EXDEV; }
        return Some(-1);
    }
    
    // If VFS-to-VFS rename, update manifest via IPC
    if old_in_vfs && new_in_vfs {
        if crate::ipc::sync_ipc_manifest_rename(&state.socket_path, old_str, new_str) {
            return Some(0);
        }
        // If IPC fails, fallback to real rename
    }
    
    None // Let real syscall handle non-VFS renames
}

#[no_mangle]
pub unsafe extern "C" fn rename_shim(old: *const c_char, new: *const c_char) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_char, *const c_char) -> c_int>(IT_RENAME.old_func);
    if INITIALIZING.load(Ordering::Relaxed) {
        return real(old, new);
    }
    rename_impl(old, new).unwrap_or_else(|| real(old, new))
}

#[no_mangle]
pub unsafe extern "C" fn rmdir_shim(path: *const c_char) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_char) -> c_int>(IT_RMDIR.old_func);
    real(path)
}

#[no_mangle]
pub unsafe extern "C" fn utimensat_shim(dirfd: c_int, path: *const c_char, times: *const libc::timespec, flags: c_int) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(c_int, *const c_char, *const libc::timespec, c_int) -> c_int>(IT_UTIMENSAT.old_func);
    real(dirfd, path, times, flags)
}

#[no_mangle]
pub unsafe extern "C" fn mkdir_shim(path: *const c_char, mode: mode_t) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_char, mode_t) -> c_int>(IT_MKDIR.old_func);
    real(path, mode)
}

#[no_mangle]
pub unsafe extern "C" fn symlink_shim(p1: *const c_char, p2: *const c_char) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_char, *const c_char) -> c_int>(IT_SYMLINK.old_func);
    real(p1, p2)
}

#[no_mangle]
pub unsafe extern "C" fn flock_shim(fd: c_int, op: c_int) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(c_int, c_int) -> c_int>(IT_FLOCK.old_func);
    real(fd, op)
}

#[no_mangle]
pub unsafe extern "C" fn readlink_shim(path: *const c_char, buf: *mut c_char, size: size_t) -> ssize_t {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_char, *mut c_char, size_t) -> ssize_t>(IT_READLINK.old_func);
    real(path, buf, size)
}

#[no_mangle]
pub unsafe extern "C" fn realpath_shim(path: *const c_char, resolved: *mut c_char) -> *mut c_char {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_char, *mut c_char) -> *mut c_char>(IT_REALPATH.old_func);
    real(path, resolved)
}

#[no_mangle]
pub unsafe extern "C" fn mmap_shim(addr: *mut c_void, len: size_t, prot: c_int, flags: c_int, fd: c_int, offset: libc::off_t) -> *mut c_void {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*mut c_void, size_t, c_int, c_int, c_int, libc::off_t) -> *mut c_void>(IT_MMAP.old_func);
    real(addr, len, prot, flags, fd, offset)
}

#[no_mangle]
pub unsafe extern "C" fn munmap_shim(addr: *mut c_void, len: size_t) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*mut c_void, size_t) -> c_int>(IT_MUNMAP.old_func);
    real(addr, len)
}

#[no_mangle]
pub unsafe extern "C" fn dlopen_shim(path: *const c_char, flags: c_int) -> *mut c_void {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_char, c_int) -> *mut c_void>(IT_DLOPEN.old_func);
    real(path, flags)
}

#[no_mangle]
pub unsafe extern "C" fn dlsym_shim(handle: *mut c_void, symbol: *const c_char) -> *mut c_void {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*mut c_void, *const c_char) -> *mut c_void>(IT_DLSYM.old_func);
    real(handle, symbol)
}

#[no_mangle]
pub unsafe extern "C" fn access_shim(path: *const c_char, mode: c_int) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_char, c_int) -> c_int>(IT_ACCESS.old_func);
    real(path, mode)
}

#[no_mangle]
pub unsafe extern "C" fn fcntl_shim(fd: c_int, cmd: c_int, arg: c_int) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(c_int, c_int, c_int) -> c_int>(IT_FCNTL.old_func);
    real(fd, cmd, arg)
}

#[no_mangle]
pub unsafe extern "C" fn faccessat_shim(dirfd: c_int, path: *const c_char, mode: c_int, flags: c_int) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(c_int, *const c_char, c_int, c_int) -> c_int>(IT_FACCESSAT.old_func);
    real(dirfd, path, mode, flags)
}

#[no_mangle]
pub unsafe extern "C" fn fstatat_shim(dirfd: c_int, path: *const c_char, buf: *mut libc::stat, flags: c_int) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(c_int, *const c_char, *mut libc::stat, c_int) -> c_int>(IT_FSTATAT.old_func);
    real(dirfd, path, buf, flags)
}

#[no_mangle]
pub unsafe extern "C" fn execve_shim(path: *const c_char, argv: *const *const c_char, envp: *const *const c_char) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_char, *const *const c_char, *const *const c_char) -> c_int>(IT_EXECVE.old_func);
    real(path, argv, envp)
}

#[no_mangle]
pub unsafe extern "C" fn posix_spawn_shim(pid: *mut libc::pid_t, path: *const c_char, actions: *const c_void, attrp: *const c_void, argv: *const *const c_char, envp: *const *const c_char) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*mut libc::pid_t, *const c_char, *const c_void, *const c_void, *const *const c_char, *const *const c_char) -> c_int>(IT_POSIX_SPAWN.old_func);
    real(pid, path, actions, attrp, argv, envp)
}

#[no_mangle]
pub unsafe extern "C" fn posix_spawnp_shim(pid: *mut libc::pid_t, file: *const c_char, actions: *const c_void, attrp: *const c_void, argv: *const *const c_char, envp: *const *const c_char) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*mut libc::pid_t, *const c_char, *const c_void, *const c_void, *const *const c_char, *const *const c_char) -> c_int>(IT_POSIX_SPAWNP.old_func);
    real(pid, file, actions, attrp, argv, envp)
}

#[no_mangle]
pub unsafe extern "C" fn link_shim(old: *const c_char, new: *const c_char) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(*const c_char, *const c_char) -> c_int>(IT_LINK.old_func);
    real(old, new)
}

#[no_mangle]
pub unsafe extern "C" fn linkat_shim(oldfd: c_int, old: *const c_char, newfd: c_int, new: *const c_char, flags: c_int) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(c_int, *const c_char, c_int, *const c_char, c_int) -> c_int>(IT_LINKAT.old_func);
    real(oldfd, old, newfd, new, flags)
}

#[no_mangle]
pub unsafe extern "C" fn renameat_shim(oldfd: c_int, old: *const c_char, newfd: c_int, new: *const c_char) -> c_int {
    let real = std::mem::transmute::<*const (), unsafe extern "C" fn(c_int, *const c_char, c_int, *const c_char) -> c_int>(IT_RENAMEAT.old_func);
    real(oldfd, old, newfd, new)
}
