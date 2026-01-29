//! # velo-shim
//!
//! LD_PRELOAD / DYLD_INSERT_LIBRARIES shim for Velo Rift virtual filesystem.
//!
//! This shared library intercepts filesystem syscalls (`open`, `stat`, `read`, etc.)
//! and redirects them through the Velo manifest and CAS.
//!
//! ## Usage (Linux)
//!
//! ```bash
//! VELO_MANIFEST=/path/to/manifest.bin \
//! VELO_CAS_ROOT=/var/velo/the_source \
//! LD_PRELOAD=/path/to/libvelo_shim.so \
//! python -c "import numpy"
//! ```
//!
//! ## Usage (macOS)
//!
//! ```bash
//! VELO_MANIFEST=/path/to/manifest.bin \
//! VELO_CAS_ROOT=/var/velo/the_source \
//! DYLD_INSERT_LIBRARIES=/path/to/libvelo_shim.dylib \
//! python -c "import numpy"
//! ```
//!
//! ## Environment Variables
//!
//! - `VELO_MANIFEST`: Path to the manifest file (required)
//! - `VELO_CAS_ROOT`: Path to CAS root directory (default: `/var/velo/the_source`)
//! - `VELO_VFS_PREFIX`: Virtual path prefix to intercept (default: `/velo`)
//! - `VELO_DEBUG`: Enable debug logging if set

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::unix::io::RawFd;
use std::path::PathBuf;
use std::ptr;
use std::sync::OnceLock;

use libc::{c_char, c_int, c_void, mode_t, size_t, ssize_t};
use memmap2::Mmap;
use velo_cas::CasStore;
use velo_manifest::Manifest;

// ============================================================================
// Platform-specific errno handling
// ============================================================================

#[cfg(target_os = "linux")]
unsafe fn set_errno(errno: c_int) {
    *libc::__errno_location() = errno;
}

#[cfg(target_os = "macos")]
unsafe fn set_errno(errno: c_int) {
    *libc::__error() = errno;
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
unsafe fn set_errno(_errno: c_int) {
    // Unsupported platform - no-op
}

// ============================================================================
// Global State
// ============================================================================

/// Global shim state, initialized on first syscall
static SHIM_STATE: OnceLock<ShimState> = OnceLock::new();

/// Thread-local file descriptor mapping
thread_local! {
    static FD_MAP: RefCell<HashMap<RawFd, VeloFd>> = RefCell::new(HashMap::new());
}

/// State for a Velo-managed file descriptor
struct VeloFd {
    /// Memory-mapped content
    mmap: Mmap,
    /// Current read position
    position: usize,
    /// Virtual path (for debugging)
    #[allow(dead_code)]
    vpath: String,
}

/// Global shim state
struct ShimState {
    /// The manifest for path lookups
    manifest: Manifest,
    /// CAS store for content retrieval
    cas: CasStore,
    /// Virtual path prefix (paths starting with this are intercepted)
    vfs_prefix: String,
    /// Debug mode enabled
    debug: bool,
}

impl ShimState {
    fn init() -> Option<Self> {
        let manifest_path = std::env::var("VELO_MANIFEST").ok()?;
        let cas_root = std::env::var("VELO_CAS_ROOT")
            .unwrap_or_else(|_| "/var/velo/the_source".to_string());
        let vfs_prefix = std::env::var("VELO_VFS_PREFIX")
            .unwrap_or_else(|_| "/velo".to_string());
        let debug = std::env::var("VELO_DEBUG").is_ok();

        if debug {
            eprintln!("[velo-shim] Initializing with manifest: {}", manifest_path);
            eprintln!("[velo-shim] CAS root: {}", cas_root);
            eprintln!("[velo-shim] VFS prefix: {}", vfs_prefix);
        }

        let manifest = Manifest::load(&manifest_path).ok()?;
        let cas = CasStore::new(&cas_root).ok()?;

        Some(Self {
            manifest,
            cas,
            vfs_prefix,
            debug,
        })
    }

    fn get() -> Option<&'static Self> {
        SHIM_STATE.get_or_init(|| Self::init().unwrap_or_else(|| {
            // Return a dummy state that doesn't intercept anything
            ShimState {
                manifest: Manifest::new(),
                cas: CasStore::new("/tmp/velo-shim-dummy").unwrap(),
                vfs_prefix: "/nonexistent-velo-prefix".to_string(),
                debug: false,
            }
        }));
        let state = SHIM_STATE.get()?;
        // Only return state if manifest is non-empty (properly initialized)
        if state.manifest.is_empty() && state.vfs_prefix == "/nonexistent-velo-prefix" {
            None
        } else {
            Some(state)
        }
    }

    fn should_intercept(&self, path: &str) -> bool {
        path.starts_with(&self.vfs_prefix)
    }

    fn debug_log(&self, msg: &str) {
        if self.debug {
            eprintln!("[velo-shim] {}", msg);
        }
    }
}

// ============================================================================
// Original libc function pointers
// ============================================================================

type OpenFn = unsafe extern "C" fn(*const c_char, c_int, mode_t) -> c_int;
type ReadFn = unsafe extern "C" fn(c_int, *mut c_void, size_t) -> ssize_t;
type CloseFn = unsafe extern "C" fn(c_int) -> c_int;
type StatFn = unsafe extern "C" fn(*const c_char, *mut libc::stat) -> c_int;
type FstatFn = unsafe extern "C" fn(c_int, *mut libc::stat) -> c_int;
type LseekFn = unsafe extern "C" fn(c_int, libc::off_t, c_int) -> libc::off_t;

static REAL_OPEN: OnceLock<OpenFn> = OnceLock::new();
static REAL_READ: OnceLock<ReadFn> = OnceLock::new();
static REAL_CLOSE: OnceLock<CloseFn> = OnceLock::new();
static REAL_STAT: OnceLock<StatFn> = OnceLock::new();
static REAL_FSTAT: OnceLock<FstatFn> = OnceLock::new();
static REAL_LSEEK: OnceLock<LseekFn> = OnceLock::new();

macro_rules! get_real_fn {
    ($static:ident, $name:literal, $type:ty) => {{
        $static.get_or_init(|| {
            let name = CString::new($name).unwrap();
            unsafe {
                let ptr = libc::dlsym(libc::RTLD_NEXT, name.as_ptr());
                if ptr.is_null() {
                    panic!("Failed to find {}", $name);
                }
                std::mem::transmute::<*mut c_void, $type>(ptr)
            }
        })
    }};
}

// ============================================================================
// Helper functions
// ============================================================================

fn path_from_cstr(path: *const c_char) -> Option<String> {
    if path.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(path).to_str().ok().map(String::from) }
}

/// Get the next available fake FD (negative to avoid conflicts)
fn allocate_velo_fd() -> RawFd {
    static NEXT_FD: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(-1000);
    NEXT_FD.fetch_sub(1, std::sync::atomic::Ordering::SeqCst)
}

fn is_velo_fd(fd: RawFd) -> bool {
    fd < -100  // Our fake FDs are very negative
}

// ============================================================================
// Intercepted syscalls
// ============================================================================

/// Intercept open() syscall
#[no_mangle]
pub unsafe extern "C" fn open(path: *const c_char, flags: c_int, mode: mode_t) -> c_int {
    let real_open = get_real_fn!(REAL_OPEN, "open", OpenFn);

    let Some(path_str) = path_from_cstr(path) else {
        return real_open(path, flags, mode);
    };

    let Some(state) = ShimState::get() else {
        return real_open(path, flags, mode);
    };

    if !state.should_intercept(&path_str) {
        return real_open(path, flags, mode);
    }

    state.debug_log(&format!("open({})", path_str));

    // Look up in manifest
    let Some(entry) = state.manifest.get(&path_str) else {
        state.debug_log("  -> not in manifest");
        set_errno(libc::ENOENT);
        return -1;
    };

    if entry.is_dir() {
        state.debug_log("  -> is directory");
        set_errno(libc::EISDIR);
        return -1;
    }

    // Get content from CAS
    let content = match state.cas.get(&entry.content_hash) {
        Ok(data) => data,
        Err(e) => {
            state.debug_log(&format!("  -> CAS error: {}", e));
            set_errno(libc::EIO);
            return -1;
        }
    };

    // Create memory mapping via temp file
    // TODO: Use memfd_create on Linux for true zero-copy
    let temp_path = format!("/tmp/velo-shim-{}", std::process::id());
    let temp_file_path = PathBuf::from(&temp_path)
        .join(CasStore::hash_to_hex(&entry.content_hash));
    
    if !temp_file_path.exists() {
        std::fs::create_dir_all(&temp_path).ok();
        std::fs::write(&temp_file_path, &content).ok();
    }

    let file = match std::fs::File::open(&temp_file_path) {
        Ok(f) => f,
        Err(_) => {
            set_errno(libc::EIO);
            return -1;
        }
    };

    let mmap = match unsafe { Mmap::map(&file) } {
        Ok(m) => m,
        Err(_) => {
            set_errno(libc::EIO);
            return -1;
        }
    };

    let velo_fd = allocate_velo_fd();
    
    FD_MAP.with(|map| {
        map.borrow_mut().insert(velo_fd, VeloFd {
            mmap,
            position: 0,
            vpath: path_str.clone(),
        });
    });

    state.debug_log(&format!("  -> fd={}", velo_fd));
    velo_fd
}

/// Intercept read() syscall
#[no_mangle]
pub unsafe extern "C" fn read(fd: c_int, buf: *mut c_void, count: size_t) -> ssize_t {
    let real_read = get_real_fn!(REAL_READ, "read", ReadFn);

    if !is_velo_fd(fd) {
        return real_read(fd, buf, count);
    }

    FD_MAP.with(|map| {
        let mut map = map.borrow_mut();
        let Some(vfd) = map.get_mut(&fd) else {
            set_errno(libc::EBADF);
            return -1;
        };

        let remaining = vfd.mmap.len().saturating_sub(vfd.position);
        let to_read = count.min(remaining);

        if to_read == 0 {
            return 0;  // EOF
        }

        ptr::copy_nonoverlapping(
            vfd.mmap.as_ptr().add(vfd.position),
            buf as *mut u8,
            to_read,
        );

        vfd.position += to_read;
        to_read as ssize_t
    })
}

/// Intercept close() syscall
#[no_mangle]
pub unsafe extern "C" fn close(fd: c_int) -> c_int {
    let real_close = get_real_fn!(REAL_CLOSE, "close", CloseFn);

    if !is_velo_fd(fd) {
        return real_close(fd);
    }

    FD_MAP.with(|map| {
        map.borrow_mut().remove(&fd);
    });

    0
}

/// Intercept lseek() syscall
#[no_mangle]
pub unsafe extern "C" fn lseek(fd: c_int, offset: libc::off_t, whence: c_int) -> libc::off_t {
    let real_lseek = get_real_fn!(REAL_LSEEK, "lseek", LseekFn);

    if !is_velo_fd(fd) {
        return real_lseek(fd, offset, whence);
    }

    FD_MAP.with(|map| {
        let mut map = map.borrow_mut();
        let Some(vfd) = map.get_mut(&fd) else {
            set_errno(libc::EBADF);
            return -1;
        };

        let new_pos = match whence {
            libc::SEEK_SET => offset as usize,
            libc::SEEK_CUR => (vfd.position as i64 + offset as i64) as usize,
            libc::SEEK_END => (vfd.mmap.len() as i64 + offset as i64) as usize,
            _ => {
                set_errno(libc::EINVAL);
                return -1;
            }
        };

        if new_pos > vfd.mmap.len() {
            set_errno(libc::EINVAL);
            return -1;
        }

        vfd.position = new_pos;
        new_pos as libc::off_t
    })
}

/// Intercept stat() syscall
#[no_mangle]
pub unsafe extern "C" fn stat(path: *const c_char, statbuf: *mut libc::stat) -> c_int {
    let real_stat = get_real_fn!(REAL_STAT, "stat", StatFn);

    let Some(path_str) = path_from_cstr(path) else {
        return real_stat(path, statbuf);
    };

    let Some(state) = ShimState::get() else {
        return real_stat(path, statbuf);
    };

    if !state.should_intercept(&path_str) {
        return real_stat(path, statbuf);
    }

    state.debug_log(&format!("stat({})", path_str));

    let Some(entry) = state.manifest.get(&path_str) else {
        set_errno(libc::ENOENT);
        return -1;
    };

    // Fill stat buffer
    let stat = &mut *statbuf;
    ptr::write_bytes(stat, 0, 1);  // Zero-initialize
    
    stat.st_size = entry.size as libc::off_t;
    stat.st_mtime = entry.mtime as libc::time_t;
    
    // Handle mode - platform-specific type
    #[cfg(target_os = "macos")]
    {
        stat.st_mode = entry.mode as u16;
    }
    #[cfg(target_os = "linux")]
    {
        stat.st_mode = entry.mode;
    }
    
    if entry.is_dir() {
        stat.st_mode |= libc::S_IFDIR as libc::mode_t;
        stat.st_nlink = 2;
    } else {
        stat.st_mode |= libc::S_IFREG as libc::mode_t;
        stat.st_nlink = 1;
    }

    0
}

/// Intercept lstat() syscall (same as stat for our purposes)
#[no_mangle]
pub unsafe extern "C" fn lstat(path: *const c_char, statbuf: *mut libc::stat) -> c_int {
    stat(path, statbuf)
}

/// Intercept fstat() syscall
#[no_mangle]
pub unsafe extern "C" fn fstat(fd: c_int, statbuf: *mut libc::stat) -> c_int {
    let real_fstat = get_real_fn!(REAL_FSTAT, "fstat", FstatFn);

    if !is_velo_fd(fd) {
        return real_fstat(fd, statbuf);
    }

    FD_MAP.with(|map| {
        let map = map.borrow();
        let Some(vfd) = map.get(&fd) else {
            set_errno(libc::EBADF);
            return -1;
        };

        let stat = &mut *statbuf;
        ptr::write_bytes(stat, 0, 1);
        
        stat.st_size = vfd.mmap.len() as libc::off_t;
        stat.st_nlink = 1;

        #[cfg(target_os = "macos")]
        {
            stat.st_mode = (libc::S_IFREG | 0o644) as u16;
        }
        #[cfg(target_os = "linux")]
        {
            stat.st_mode = libc::S_IFREG | 0o644;
        }

        0
    })
}

// ============================================================================
// Linux-specific syscall wrappers (__xstat family)
// ============================================================================

#[cfg(target_os = "linux")]
mod linux_compat {
    use super::*;

    /// Intercept __xstat() (glibc internal)
    #[no_mangle]
    pub unsafe extern "C" fn __xstat(_ver: c_int, path: *const c_char, statbuf: *mut libc::stat) -> c_int {
        stat(path, statbuf)
    }

    /// Intercept __lxstat() (glibc internal)
    #[no_mangle]
    pub unsafe extern "C" fn __lxstat(_ver: c_int, path: *const c_char, statbuf: *mut libc::stat) -> c_int {
        lstat(path, statbuf)
    }

    /// Intercept __fxstat() (glibc internal)
    #[no_mangle]
    pub unsafe extern "C" fn __fxstat(_ver: c_int, fd: c_int, statbuf: *mut libc::stat) -> c_int {
        fstat(fd, statbuf)
    }

    /// Intercept open64() (same as open on 64-bit)
    #[no_mangle]
    pub unsafe extern "C" fn open64(path: *const c_char, flags: c_int, mode: mode_t) -> c_int {
        open(path, flags, mode)
    }
}

// ============================================================================
// Module initialization (constructor)
// ============================================================================

/// Called when the library is loaded
#[used]
#[cfg_attr(target_os = "linux", link_section = ".init_array")]
#[cfg_attr(target_os = "macos", link_section = "__DATA,__mod_init_func")]
static INIT: extern "C" fn() = {
    extern "C" fn init() {
        // Pre-initialize state to avoid lazy init during syscalls
        let _ = ShimState::get();
    }
    init
};
