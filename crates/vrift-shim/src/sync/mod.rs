pub mod fd_table;
pub mod recursive_mutex;
pub mod ring_buffer;

pub use fd_table::FdTable;
pub use recursive_mutex::RecursiveMutex;
pub use ring_buffer::{RingBuffer, Task};

use std::cell::UnsafeCell;
use std::sync::atomic::AtomicBool;

/// Global Reactor State
pub struct Reactor {
    pub fd_table: FdTable,
    pub ring_buffer: RingBuffer,
    pub started: AtomicBool,
}

// We'll use a manually managed static for the Reactor to avoid init hazards
pub static mut REACTOR: UnsafeCell<Option<Reactor>> = UnsafeCell::new(None);
static REACTOR_INITIALIZED: AtomicBool = AtomicBool::new(false);

#[inline(always)]
pub fn get_reactor() -> Option<&'static Reactor> {
    // Fast path: check atomic flag first (relaxed is fine for initialized state)
    if !REACTOR_INITIALIZED.load(std::sync::atomic::Ordering::Relaxed) {
        return None;
    }
    unsafe { (*REACTOR.get()).as_ref() }
}

/// Called once during initialization
pub(crate) unsafe fn mark_reactor_ready() {
    REACTOR_INITIALIZED.store(true, std::sync::atomic::Ordering::Release);
}

/// UNSAFE: Only call after Reactor is initialized (post-init phase)
/// This skips the initialization check for maximum performance
#[inline(always)]
pub unsafe fn get_reactor_unchecked() -> &'static Reactor {
    (*REACTOR.get()).as_ref().unwrap_unchecked()
}
