// =============================================================================
// RawContext: Compile-time Safety Boundary for the Inception Layer
// =============================================================================
//
// This module provides a zero-sized marker type that enforces the raw-syscall
// safety boundary at the TYPE SYSTEM level.
//
// Functions that accept `&RawContext` are guaranteed to only call raw syscalls
// (inline assembly on ARM64, direct syscall on x86_64). They will NEVER call
// libc wrappers (libc::close, libc::access, etc.) which would be re-intercepted
// by the shim and cause recursive IPC deadlock (BUG-007b).
//
// Usage:
//   fn my_ipc_function(ctx: &RawContext, ...) {
//       ctx.close(fd);         // ✅ Compiles — uses raw syscall
//       libc::close(fd);       // ⚠️ Code review red flag — bypasses RawContext
//   }
//
// The RawContext cannot be constructed outside this crate (private field),
// ensuring only inception-layer code can use it.
// =============================================================================

use libc::{c_int, c_void, size_t, ssize_t};

/// Compile-time safety boundary for inception layer IPC.
///
/// All methods on this type delegate to raw syscalls (inline assembly),
/// completely bypassing libc. This prevents BUG-007b class bugs where
/// libc wrappers are re-intercepted by the shim.
///
/// # Construction
///
/// `RawContext` has a private field and cannot be constructed outside this crate.
/// Use [`RawContext::INSTANCE`] to obtain a reference.
pub struct RawContext {
    _private: (),
}

impl RawContext {
    /// Singleton instance. Zero-sized, no runtime cost.
    pub(crate) const INSTANCE: Self = Self { _private: () };

    // =========================================================================
    // Core I/O — used by IPC (ipc.rs)
    // =========================================================================

    /// Raw close syscall. Avoids interposed `close_inception`.
    #[inline(always)]
    pub unsafe fn close(&self, fd: c_int) -> c_int {
        #[cfg(target_os = "macos")]
        {
            crate::syscalls::macos_raw::raw_close(fd)
        }
        #[cfg(target_os = "linux")]
        {
            crate::syscalls::linux_raw::raw_close(fd)
        }
    }

    /// Raw access syscall. Avoids interposed `access_inception`.
    #[inline(always)]
    pub unsafe fn access(&self, path: *const libc::c_char, mode: c_int) -> c_int {
        #[cfg(target_os = "macos")]
        {
            crate::syscalls::macos_raw::raw_access(path, mode)
        }
        #[cfg(target_os = "linux")]
        {
            crate::syscalls::linux_raw::raw_access(path, mode)
        }
    }

    /// Raw fcntl syscall. Avoids interposed `fcntl`.
    #[inline(always)]
    pub unsafe fn fcntl(&self, fd: c_int, cmd: c_int, arg: c_int) -> c_int {
        #[cfg(target_os = "macos")]
        {
            crate::syscalls::macos_raw::raw_fcntl(fd, cmd, arg)
        }
        #[cfg(target_os = "linux")]
        {
            // Linux fcntl is not interposed, but use raw for consistency
            libc::fcntl(fd, cmd, arg)
        }
    }

    /// Raw read syscall. Avoids interposed `read`.
    #[inline(always)]
    pub unsafe fn read(&self, fd: c_int, buf: *mut c_void, count: size_t) -> ssize_t {
        #[cfg(target_os = "macos")]
        {
            crate::syscalls::macos_raw::raw_read(fd, buf, count)
        }
        #[cfg(target_os = "linux")]
        {
            crate::syscalls::linux_raw::raw_read(fd, buf, count)
        }
    }

    /// Raw write syscall. Avoids interposed `write`.
    #[inline(always)]
    pub unsafe fn write(&self, fd: c_int, buf: *const c_void, count: size_t) -> ssize_t {
        #[cfg(target_os = "macos")]
        {
            crate::syscalls::macos_raw::raw_write(fd, buf, count)
        }
        #[cfg(target_os = "linux")]
        {
            crate::syscalls::linux_raw::raw_write(fd, buf, count)
        }
    }

    // =========================================================================
    // Composite I/O helpers — higher-level operations built on raw primitives
    // =========================================================================

    /// Write all bytes to fd, retrying on partial writes. Zero libc dependency.
    #[inline]
    pub unsafe fn write_all(&self, fd: c_int, data: &[u8]) -> bool {
        let mut written = 0;
        while written < data.len() {
            let n = self.write(
                fd,
                data[written..].as_ptr() as *const c_void,
                data.len() - written,
            );
            if n <= 0 {
                return false;
            }
            written += n as usize;
        }
        true
    }

    /// Read exactly `buf.len()` bytes from fd. Zero libc dependency.
    #[inline]
    pub unsafe fn read_exact(&self, fd: c_int, buf: &mut [u8]) -> bool {
        let mut read = 0;
        while read < buf.len() {
            let n = self.read(
                fd,
                buf[read..].as_mut_ptr() as *mut c_void,
                buf.len() - read,
            );
            if n <= 0 {
                return false;
            }
            read += n as usize;
        }
        true
    }
}
