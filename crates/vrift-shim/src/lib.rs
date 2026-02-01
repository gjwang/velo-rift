//! # velo-shim
//!
//! LD_PRELOAD / DYLD_INSERT_LIBRARIES shim for Velo Rift virtual filesystem.
//! Industrial-grade, zero-allocation, and recursion-safe.

// Allow dead code during incremental restoration - functions will be connected in later phases
#![allow(dead_code)]

pub mod interpose;
pub mod ipc;
pub mod state;
pub mod syscalls;

// Re-export for linkage
pub use interpose::*;
pub use state::LOGGER;
pub use syscalls::*;

/// RFC-0049: Static constructor for macOS to signal that the library
/// has been loaded and symbol resolution is complete.
/// This safely clears the INITIALIZING flag to enable shims.
#[cfg(target_os = "macos")]
#[link_section = "__DATA,__mod_init_func"]
pub static SET_READY: unsafe extern "C" fn() = {
    unsafe extern "C" fn ready() {
        crate::state::INITIALIZING.store(false, std::sync::atomic::Ordering::SeqCst);
    }
    ready
};
