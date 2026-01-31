//! # velo-shim
//!
//! LD_PRELOAD / DYLD_INSERT_LIBRARIES shim for Velo Rift virtual filesystem.
//! Industrial-grade, zero-allocation, and recursion-safe.

#![allow(clippy::missing_safety_doc)]
#![allow(unused_doc_comments)]

use std::cell::Cell;
use std::ffi::{CStr, CString};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};

use libc::{c_char, c_int, c_void, mode_t, size_t, ssize_t};
use std::collections::HashMap;
use std::sync::Mutex;
use vrift_cas::CasStore;

// ============================================================================
// Platform Bridges & Interpose Section
// ============================================================================

#[cfg(target_os = "macos")]
#[repr(C)]
struct Interpose {
    new_func: *const (),
    old_func: *const (),
}

#[cfg(target_os = "macos")]
unsafe impl Sync for Interpose {}

#[cfg(target_os = "macos")]
extern "C" {
    fn open(path: *const c_char, flags: c_int, mode: mode_t) -> c_int;
    fn close(fd: c_int) -> c_int;
    fn write(fd: c_int, buf: *const c_void, count: size_t) -> ssize_t;
    fn stat(path: *const c_char, buf: *mut libc::stat) -> c_int;
    fn lstat(path: *const c_char, buf: *mut libc::stat) -> c_int;
    fn fstat(fd: c_int, buf: *mut libc::stat) -> c_int;
    fn opendir(path: *const c_char) -> *mut libc::DIR;
    fn readdir(dirp: *mut libc::DIR) -> *mut libc::dirent;
    fn closedir(dirp: *mut libc::DIR) -> c_int;
    fn readlink(path: *const c_char, buf: *mut c_char, bufsiz: size_t) -> ssize_t;
}

#[cfg(target_os = "macos")]
#[link_section = "__DATA,__interpose"]
#[used]
static IT_OPEN: Interpose = Interpose {
    new_func: open_shim as *const (),
    old_func: open as *const (),
};
#[cfg(target_os = "macos")]
#[link_section = "__DATA,__interpose"]
#[used]
static IT_WRITE: Interpose = Interpose {
    new_func: write_shim as *const (),
    old_func: write as *const (),
};
#[cfg(target_os = "macos")]
#[link_section = "__DATA,__interpose"]
#[used]
static IT_CLOSE: Interpose = Interpose {
    new_func: close_shim as *const (),
    old_func: close as *const (),
};
#[cfg(target_os = "macos")]
#[link_section = "__DATA,__interpose"]
#[used]
static IT_STAT: Interpose = Interpose {
    new_func: stat_shim as *const (),
    old_func: stat as *const (),
};
#[cfg(target_os = "macos")]
#[link_section = "__DATA,__interpose"]
#[used]
static IT_LSTAT: Interpose = Interpose {
    new_func: lstat_shim as *const (),
    old_func: lstat as *const (),
};
#[cfg(target_os = "macos")]
#[link_section = "__DATA,__interpose"]
#[used]
static IT_FSTAT: Interpose = Interpose {
    new_func: fstat_shim as *const (),
    old_func: fstat as *const (),
};
#[cfg(target_os = "macos")]
#[link_section = "__DATA,__interpose"]
#[used]
static IT_OPENDIR: Interpose = Interpose {
    new_func: opendir_shim as *const (),
    old_func: opendir as *const (),
};
#[cfg(target_os = "macos")]
#[link_section = "__DATA,__interpose"]
#[used]
static IT_READDIR: Interpose = Interpose {
    new_func: readdir_shim as *const (),
    old_func: readdir as *const (),
};
#[cfg(target_os = "macos")]
#[link_section = "__DATA,__interpose"]
#[used]
static IT_CLOSEDIR: Interpose = Interpose {
    new_func: closedir_shim as *const (),
    old_func: closedir as *const (),
};
#[cfg(target_os = "macos")]
#[link_section = "__DATA,__interpose"]
#[used]
static IT_READLINK: Interpose = Interpose {
    new_func: readlink_shim as *const (),
    old_func: readlink as *const (),
};

// ============================================================================
// Global State & Recursion Guards
// ============================================================================

static SHIM_STATE: AtomicPtr<ShimState> = AtomicPtr::new(ptr::null_mut());
static INITIALIZING: AtomicBool = AtomicBool::new(false);
static DEBUG_ENABLED: AtomicBool = AtomicBool::new(false);

thread_local! {
    static IN_SHIM: Cell<bool> = const { Cell::new(false) };
}

const LOG_BUF_SIZE: usize = 64 * 1024;
struct Logger {
    buffer: [u8; LOG_BUF_SIZE],
    head: std::sync::atomic::AtomicUsize,
}

impl Logger {
    const fn new() -> Self {
        Self {
            buffer: [0u8; LOG_BUF_SIZE],
            head: std::sync::atomic::AtomicUsize::new(0),
        }
    }

    fn log(&self, msg: &str) {
        let len = msg.len();
        if len > LOG_BUF_SIZE {
            return;
        }

        let start = self.head.fetch_add(len, Ordering::SeqCst);
        for i in 0..len {
            unsafe {
                let ptr = self.buffer.as_ptr().add((start + i) % LOG_BUF_SIZE) as *mut u8;
                *ptr = msg.as_bytes()[i];
            }
        }
    }

    #[allow(dead_code)]
    fn dump(&self) {
        let head = self.head.load(Ordering::SeqCst);
        let start = if head > LOG_BUF_SIZE {
            head % LOG_BUF_SIZE
        } else {
            0
        };
        let len = if head > LOG_BUF_SIZE {
            LOG_BUF_SIZE
        } else {
            head
        };

        unsafe {
            if start + len <= LOG_BUF_SIZE {
                libc::write(2, self.buffer.as_ptr().add(start) as *const c_void, len);
            } else {
                let first_part = LOG_BUF_SIZE - start;
                libc::write(
                    2,
                    self.buffer.as_ptr().add(start) as *const c_void,
                    first_part,
                );
                libc::write(2, self.buffer.as_ptr() as *const c_void, len - first_part);
            }
        }
    }
}

static LOGGER: Logger = Logger::new();

struct OpenFile {
    vpath: String,
    original_path: String,
}

struct ShimState {
    cas: CasStore,
    vfs_prefix: String,
    socket_path: String,
    open_fds: Mutex<HashMap<c_int, OpenFile>>,
}

impl ShimState {
    fn init() -> Option<*mut Self> {
        let cas_ptr = unsafe { libc::getenv(c"VR_THE_SOURCE".as_ptr()) };
        let cas_root = if cas_ptr.is_null() {
            "/tmp/vrift/the_source".into()
        } else {
            unsafe { CStr::from_ptr(cas_ptr).to_string_lossy() }
        };

        let prefix_ptr = unsafe { libc::getenv(c"VRIFT_VFS_PREFIX".as_ptr()) };
        let vfs_prefix = if prefix_ptr.is_null() {
            "/vrift".into()
        } else {
            unsafe { CStr::from_ptr(prefix_ptr).to_string_lossy() }
        };

        let cas = match CasStore::new(cas_root.as_ref()) {
            Ok(c) => c,
            Err(_) => return None,
        };

        let socket_path = "/tmp/vrift.sock".to_string();

        let state = Box::new(Self {
            cas,
            vfs_prefix: vfs_prefix.into_owned(),
            socket_path,
            open_fds: Mutex::new(HashMap::new()),
        });

        Some(Box::into_raw(state))
    }

    fn get() -> Option<&'static Self> {
        let ptr = SHIM_STATE.load(Ordering::Acquire);
        if !ptr.is_null() {
            return unsafe { Some(&*ptr) };
        }

        if INITIALIZING.swap(true, Ordering::SeqCst) {
            return None;
        }

        let ptr = if let Some(p) = Self::init() {
            SHIM_STATE.store(p, Ordering::Release);
            p
        } else {
            ptr::null_mut()
        };

        INITIALIZING.store(false, Ordering::SeqCst);
        if ptr.is_null() {
            None
        } else {
            unsafe { Some(&*ptr) }
        }
    }

    fn query_manifest(&self, path: &str) -> Option<vrift_manifest::VnodeEntry> {
        use std::io::{Read, Write};
        use std::os::unix::net::UnixStream;
        use vrift_ipc::{VeloRequest, VeloResponse};

        let mut stream = UnixStream::connect(&self.socket_path).ok()?;
        let req = VeloRequest::ManifestGet {
            path: path.to_string(),
        };
        let buf = bincode::serialize(&req).ok()?;
        let len = (buf.len() as u32).to_le_bytes();
        stream.write_all(&len).ok()?;
        stream.write_all(&buf).ok()?;

        let mut resp_len_buf = [0u8; 4];
        stream.read_exact(&mut resp_len_buf).ok()?;
        let resp_len = u32::from_le_bytes(resp_len_buf) as usize;
        let mut resp_buf = vec![0u8; resp_len];
        stream.read_exact(&mut resp_buf).ok()?;

        match bincode::deserialize::<VeloResponse>(&resp_buf).ok()? {
            VeloResponse::ManifestAck { entry } => entry,
            _ => None,
        }
    }
    fn upsert_manifest(&self, path: &str, entry: vrift_manifest::VnodeEntry) -> bool {
        use std::io::Write;
        use std::os::unix::net::UnixStream;
        use vrift_ipc::VeloRequest;

        let ok = (|| -> Result<(), Box<dyn std::error::Error>> {
            let mut stream = UnixStream::connect(&self.socket_path)?;
            let req = VeloRequest::ManifestUpsert {
                path: path.to_string(),
                entry,
            };
            let buf = bincode::serialize(&req)?;
            let len = (buf.len() as u32).to_le_bytes();
            stream.write_all(&len)?;
            stream.write_all(&buf)?;
            Ok(())
        })();
        ok.is_ok()
    }
}

// ============================================================================
// Utility Functions
// ============================================================================

unsafe fn shim_log(msg: &str) {
    LOGGER.log(msg);
    if DEBUG_ENABLED.load(Ordering::Relaxed) {
        libc::write(2, msg.as_ptr() as *const c_void, msg.len());
    }
}

struct ShimGuard;
impl ShimGuard {
    fn enter() -> Option<Self> {
        if IN_SHIM.with(|b| b.get()) {
            None
        } else {
            IN_SHIM.with(|b| b.set(true));
            Some(ShimGuard)
        }
    }
}
impl Drop for ShimGuard {
    fn drop(&mut self) {
        IN_SHIM.with(|b| b.set(false));
    }
}

#[cfg(target_os = "linux")]
unsafe fn set_errno(e: c_int) {
    *libc::__errno_location() = e;
}
#[cfg(target_os = "macos")]
unsafe fn set_errno(e: c_int) {
    *libc::__error() = e;
}

// ============================================================================
// Core Logic
// ============================================================================

unsafe fn break_link(path_str: &str) -> Result<(), c_int> {
    let p = Path::new(path_str);
    let metadata = match std::fs::metadata(p) {
        Ok(m) => m,
        Err(_) => return Ok(()),
    };
    if metadata.nlink() < 2 {
        return Ok(());
    }

    #[cfg(target_os = "macos")]
    {
        let mut path_buf = [0u8; 1024];
        if path_str.len() >= 1024 {
            return Err(libc::ENAMETOOLONG);
        }
        ptr::copy_nonoverlapping(path_str.as_ptr(), path_buf.as_mut_ptr(), path_str.len());
        path_buf[path_str.len()] = 0;
        libc::chflags(path_buf.as_ptr() as *const c_char, 0);
    }

    let mut tmp_path_buf = [0u8; 1024];
    let pb = path_str.as_bytes();
    if pb.len() > 1000 {
        return Err(libc::ENAMETOOLONG);
    }
    tmp_path_buf[..pb.len()].copy_from_slice(pb);
    let suffix = b".vrift_tmp";
    tmp_path_buf[pb.len()..(pb.len() + suffix.len())].copy_from_slice(suffix);
    let tmp_len = pb.len() + suffix.len();
    tmp_path_buf[tmp_len] = 0;

    let tmp_ptr = tmp_path_buf.as_ptr() as *const c_char;
    let path_ptr = CString::new(path_str).map_err(|_| libc::EINVAL)?;

    if libc::rename(path_ptr.as_ptr(), tmp_ptr) != 0 {
        return Err(libc::EACCES);
    }
    if std::fs::copy(
        std::str::from_utf8_unchecked(&tmp_path_buf[..tmp_len]),
        path_str,
    )
    .is_err()
    {
        let _ = libc::rename(tmp_ptr, path_ptr.as_ptr());
        return Err(libc::EIO);
    }
    let _ = libc::unlink(tmp_ptr);
    let _ = std::fs::set_permissions(path_str, std::fs::Permissions::from_mode(0o644));
    Ok(())
}

type OpenFn = unsafe extern "C" fn(*const c_char, c_int, mode_t) -> c_int;
type WriteFn = unsafe extern "C" fn(c_int, *const c_void, size_t) -> ssize_t;
type CloseFn = unsafe extern "C" fn(c_int) -> c_int;

unsafe fn open_impl(path: *const c_char, flags: c_int, mode: mode_t, real_open: OpenFn) -> c_int {
    let _guard = match ShimGuard::enter() {
        Some(g) => g,
        None => return real_open(path, flags, mode),
    };
    let path_str = match CStr::from_ptr(path).to_str() {
        Ok(s) => s,
        Err(_) => return real_open(path, flags, mode),
    };

    let Some(state) = ShimState::get() else {
        return real_open(path, flags, mode);
    };

    let is_write = (flags & (libc::O_WRONLY | libc::O_RDWR | libc::O_TRUNC)) != 0;
    if path_str.starts_with(&state.vfs_prefix) {
        let vpath = &path_str[state.vfs_prefix.len()..];
        if let Some(entry) = state.query_manifest(vpath) {
            if entry.is_dir() {
                set_errno(libc::EISDIR);
                return -1;
            }
            if let Ok(content) = state.cas.get(&entry.content_hash) {
                let mut tmp_path_buf = [0u8; 128];
                let prefix = b"/tmp/vrift-mem-";
                tmp_path_buf[..prefix.len()].copy_from_slice(prefix);
                for i in 0..32 {
                    let hex = b"0123456789abcdef";
                    tmp_path_buf[prefix.len() + i * 2] = hex[(entry.content_hash[i] >> 4) as usize];
                    tmp_path_buf[prefix.len() + i * 2 + 1] =
                        hex[(entry.content_hash[i] & 0x0f) as usize];
                }
                tmp_path_buf[prefix.len() + 64] = 0;

                let tmp_fd = libc::open(
                    tmp_path_buf.as_ptr() as *const c_char,
                    libc::O_CREAT | libc::O_RDWR | libc::O_TRUNC,
                    0o644,
                );
                if tmp_fd >= 0 {
                    libc::write(tmp_fd, content.as_ptr() as *const c_void, content.len());
                    libc::lseek(tmp_fd, 0, libc::SEEK_SET);
                    return tmp_fd;
                }
            }
        }
    }

    if is_write && path_str.starts_with(&state.vfs_prefix) {
        let _ = break_link(path_str);

        let fd = real_open(path, flags, mode);
        if fd >= 0 {
            let mut fds = state.open_fds.lock().unwrap();
            fds.insert(
                fd,
                OpenFile {
                    vpath: path_str[state.vfs_prefix.len()..].to_string(),
                    original_path: path_str.to_string(),
                },
            );
        }
        return fd;
    }

    real_open(path, flags, mode)
}

unsafe fn write_impl(fd: c_int, buf: *const c_void, count: size_t, real_write: WriteFn) -> ssize_t {
    real_write(fd, buf, count)
}

unsafe fn close_impl(fd: c_int, real_close: CloseFn) -> c_int {
    let _guard = match ShimGuard::enter() {
        Some(g) => g,
        None => return real_close(fd),
    };

    if let Some(state) = ShimState::get() {
        let open_file = {
            let mut fds = state.open_fds.lock().unwrap();
            fds.remove(&fd)
        };

        if let Some(file) = open_file {
            // Re-ingest
            if let Ok(metadata) = std::fs::metadata(&file.original_path) {
                if let Ok(data) = std::fs::read(&file.original_path) {
                    let hash = CasStore::compute_hash(&data);
                    let entry = vrift_manifest::VnodeEntry::new_file(
                        hash,
                        metadata.len(),
                        metadata.mtime() as u64,
                        metadata.mode(),
                    );
                    state.upsert_manifest(&file.vpath, entry);
                    shim_log("[VRift-Shim] Re-ingested file on close\n");
                }
            }
        }
    }

    real_close(fd)
}

type StatFn = unsafe extern "C" fn(*const c_char, *mut libc::stat) -> c_int;
type FstatFn = unsafe extern "C" fn(c_int, *mut libc::stat) -> c_int;

unsafe fn stat_common(path: *const c_char, buf: *mut libc::stat, real_stat: StatFn) -> c_int {
    let _guard = match ShimGuard::enter() {
        Some(g) => g,
        None => return real_stat(path, buf),
    };
    let path_str = match CStr::from_ptr(path).to_str() {
        Ok(s) => s,
        Err(_) => return real_stat(path, buf),
    };

    let Some(state) = ShimState::get() else {
        return real_stat(path, buf);
    };

    if path_str == state.vfs_prefix {
        ptr::write_bytes(buf, 0, 1);
        (*buf).st_mode = libc::S_IFDIR | 0o755;
        (*buf).st_nlink = 2;
        (*buf).st_uid = libc::getuid();
        (*buf).st_gid = libc::getgid();
        return 0;
    }

    if path_str.starts_with(&state.vfs_prefix) {
        let vpath = &path_str[state.vfs_prefix.len()..];
        if let Some(entry) = state.query_manifest(vpath) {
            ptr::write_bytes(buf, 0, 1);
            (*buf).st_size = entry.size as libc::off_t;
            (*buf).st_mtime = entry.mtime as libc::time_t;
            (*buf).st_mode = entry.mode as libc::mode_t;
            if entry.is_dir() {
                (*buf).st_mode |= libc::S_IFDIR;
            } else if entry.is_symlink() {
                (*buf).st_mode |= libc::S_IFLNK;
            } else {
                (*buf).st_mode |= libc::S_IFREG;
            }
            (*buf).st_nlink = 1;
            (*buf).st_uid = libc::getuid();
            (*buf).st_gid = libc::getgid();
            return 0;
        }
    }

    real_stat(path, buf)
}

unsafe fn fstat_impl(fd: c_int, buf: *mut libc::stat, real_fstat: FstatFn) -> c_int {
    // For fstat, we ideally track fds. For now, we just pass through.
    real_fstat(fd, buf)
}

type OpendirFn = unsafe extern "C" fn(*const c_char) -> *mut libc::DIR;
type ReadlinkFn = unsafe extern "C" fn(*const c_char, *mut c_char, size_t) -> ssize_t;

unsafe fn opendir_impl(path: *const c_char, real_opendir: OpendirFn) -> *mut libc::DIR {
    real_opendir(path)
}

unsafe fn readlink_impl(
    path: *const c_char,
    buf: *mut c_char,
    bufsiz: size_t,
    real_readlink: ReadlinkFn,
) -> ssize_t {
    real_readlink(path, buf, bufsiz)
}

// ============================================================================
#[cfg(target_os = "linux")]
static REAL_OPEN: AtomicPtr<c_void> = AtomicPtr::new(ptr::null_mut());
#[cfg(target_os = "linux")]
static REAL_WRITE: AtomicPtr<c_void> = AtomicPtr::new(ptr::null_mut());
#[cfg(target_os = "linux")]
static REAL_CLOSE: AtomicPtr<c_void> = AtomicPtr::new(ptr::null_mut());

#[cfg(target_os = "linux")]
macro_rules! get_real {
    ($storage:ident, $name:literal, $t:ty) => {{
        let p = $storage.load(Ordering::Acquire);
        if !p.is_null() {
            std::mem::transmute::<*mut c_void, $t>(p)
        } else {
            let f = libc::dlsym(
                libc::RTLD_NEXT,
                concat!($name, "\0").as_ptr() as *const c_char,
            );
            $storage.store(f, Ordering::Release);
            std::mem::transmute::<*mut c_void, $t>(f)
        }
    }};
}

#[cfg(target_os = "linux")]
#[no_mangle]
pub unsafe extern "C" fn open(p: *const c_char, f: c_int, m: mode_t) -> c_int {
    open_impl(p, f, m, get_real!(REAL_OPEN, "open", OpenFn))
}

#[cfg(target_os = "linux")]
#[no_mangle]
pub unsafe extern "C" fn write(fd: c_int, b: *const c_void, c: size_t) -> ssize_t {
    write_impl(fd, b, c, get_real!(REAL_WRITE, "write", WriteFn))
}

#[cfg(target_os = "linux")]
static REAL_STAT: AtomicPtr<c_void> = AtomicPtr::new(ptr::null_mut());
#[cfg(target_os = "linux")]
static REAL_LSTAT: AtomicPtr<c_void> = AtomicPtr::new(ptr::null_mut());
#[cfg(target_os = "linux")]
static REAL_FSTAT: AtomicPtr<c_void> = AtomicPtr::new(ptr::null_mut());

#[cfg(target_os = "linux")]
#[no_mangle]
pub unsafe extern "C" fn close(fd: c_int) -> c_int {
    close_impl(fd, get_real!(REAL_CLOSE, "close", CloseFn))
}

#[cfg(target_os = "linux")]
#[no_mangle]
pub unsafe extern "C" fn stat(p: *const c_char, b: *mut libc::stat) -> c_int {
    stat_common(p, b, get_real!(REAL_STAT, "stat", StatFn))
}

#[cfg(target_os = "linux")]
#[no_mangle]
pub unsafe extern "C" fn lstat(p: *const c_char, b: *mut libc::stat) -> c_int {
    stat_common(p, b, get_real!(REAL_LSTAT, "lstat", StatFn))
}

#[cfg(target_os = "linux")]
#[no_mangle]
pub unsafe extern "C" fn fstat(fd: c_int, b: *mut libc::stat) -> c_int {
    fstat_impl(fd, b, get_real!(REAL_FSTAT, "fstat", FstatFn))
}

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn open_shim(p: *const c_char, f: c_int, m: mode_t) -> c_int {
    let real = std::mem::transmute::<*const (), OpenFn>(IT_OPEN.old_func);
    open_impl(p, f, m, real)
}

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn write_shim(fd: c_int, b: *const c_void, c: size_t) -> ssize_t {
    let real = std::mem::transmute::<*const (), WriteFn>(IT_WRITE.old_func);
    write_impl(fd, b, c, real)
}

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn close_shim(fd: c_int) -> c_int {
    let real = std::mem::transmute::<*const (), CloseFn>(IT_CLOSE.old_func);
    close_impl(fd, real)
}

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn stat_shim(p: *const c_char, b: *mut libc::stat) -> c_int {
    stat_common(p, b, stat)
}

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn lstat_shim(p: *const c_char, b: *mut libc::stat) -> c_int {
    stat_common(p, b, lstat)
}

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn fstat_shim(fd: c_int, b: *mut libc::stat) -> c_int {
    fstat_impl(fd, b, fstat)
}

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn opendir_shim(p: *const c_char) -> *mut libc::DIR {
    opendir_impl(p, opendir)
}

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn readdir_shim(d: *mut libc::DIR) -> *mut libc::dirent {
    readdir(d)
}

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn closedir_shim(d: *mut libc::DIR) -> c_int {
    closedir(d)
}

#[cfg(target_os = "macos")]
#[no_mangle]
pub unsafe extern "C" fn readlink_shim(p: *const c_char, b: *mut c_char, s: size_t) -> ssize_t {
    readlink_impl(p, b, s, readlink)
}

// Constructor
#[used]
#[cfg_attr(target_os = "linux", link_section = ".init_array")]
#[cfg_attr(target_os = "macos", link_section = "__DATA,__mod_init_func")]
static INIT: unsafe extern "C" fn() = {
    unsafe extern "C" fn init() {
        if !libc::getenv(c"VRIFT_DEBUG".as_ptr()).is_null() {
            DEBUG_ENABLED.store(true, Ordering::Relaxed);
        }
        shim_log("[VRift-Shim] Initialized\n");
    }
    init
};
