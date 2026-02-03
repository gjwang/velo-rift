use crate::syscalls::io::FdEntry;
use std::ptr;
use std::sync::atomic::{AtomicPtr, Ordering};

// RFC-0051: Flat atomic array for lock-free FD tracking
// Direct indexing for maximum performance (eliminates one indirection)
const MAX_FDS: usize = 262144; // 256K FDs

/// A flat atomic array for wait-free FD tracking.
/// Optimized for extreme performance with zero indirection.
/// Fixed 2MB memory cost (~262K × 8 bytes).
#[repr(align(64))]
pub struct FdTable {
    // Direct flat array: one atomic load, zero pointer chasing
    entries: [AtomicPtr<FdEntry>; MAX_FDS],
}

impl Default for FdTable {
    fn default() -> Self {
        Self::new()
    }
}

impl FdTable {
    pub const fn new() -> Self {
        Self {
            entries: [const { AtomicPtr::new(ptr::null_mut()) }; MAX_FDS],
        }
    }

    /// Set the entry for a given FD. Returns the OLD entry if any.
    #[inline(always)]
    pub fn set(&self, fd: u32, entry: *mut FdEntry) -> *mut FdEntry {
        if fd >= MAX_FDS as u32 {
            return ptr::null_mut();
        }

        // Single atomic swap - zero indirection!
        self.entries[fd as usize].swap(entry, Ordering::AcqRel)
    }

    /// Get the entry for a given FD.
    #[inline(always)]
    pub fn get(&self, fd: u32) -> *mut FdEntry {
        if fd >= MAX_FDS as u32 {
            return ptr::null_mut();
        }

        // Single atomic load - zero indirection!
        self.entries[fd as usize].load(Ordering::Relaxed)
    }

    /// Remove an entry. Returns the removed entry.
    #[inline(always)]
    pub fn remove(&self, fd: u32) -> *mut FdEntry {
        self.set(fd, ptr::null_mut())
    }
}

// Safety: FdTable handles its own synchronization via atomics.
unsafe impl Send for FdTable {}
unsafe impl Sync for FdTable {}
