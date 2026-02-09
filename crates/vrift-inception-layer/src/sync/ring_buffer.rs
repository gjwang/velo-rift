use std::cell::UnsafeCell;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

// Force 128-byte alignment to prevent false sharing across NUMA nodes
// Modern CPUs prefetch adjacent cache lines, so we use double cache line size
#[repr(align(128))]
struct CachePadded<T>(T);

pub enum Task {
    // Metadata reclamation (High Priority)
    ReclaimFd(u32, *mut crate::syscalls::io::FdEntry),
    // IPC/Telemetry (Low Priority)
    Reingest {
        vpath: String,
        temp_path: String,
    },
    Log(String),
    /// Phase 3: Fire-and-forget IPC — pre-serialized request bytes pushed to worker.
    /// The worker connects to the socket and sends the request without blocking the caller.
    IpcFireAndForget {
        socket_path: String,
        /// Pre-serialized VeloRequest bytes (rkyv format) + IPC header
        payload: Vec<u8>,
    },
}

// Power of 2 for fast modulo via bitwise AND
const BUFFER_SIZE: usize = 4096;
const BUFFER_MASK: usize = BUFFER_SIZE - 1;

/// Performance statistics for monitoring
pub struct RingBufferStats {
    pub pushes: AtomicU64,
    pub pops: AtomicU64,
    pub push_errors: AtomicU64,
    pub max_depth: AtomicU64,
}

impl RingBufferStats {
    pub const fn new() -> Self {
        Self {
            pushes: AtomicU64::new(0),
            pops: AtomicU64::new(0),
            push_errors: AtomicU64::new(0),
            max_depth: AtomicU64::new(0),
        }
    }
}

impl Default for RingBufferStats {
    fn default() -> Self {
        Self::new()
    }
}

/// A Multi-Producer Single-Consumer Lock-Free Ring Buffer.
/// Optimized for extreme performance with cache-aware design.
#[repr(align(64))]
pub struct RingBuffer {
    // Producer-owned: padded to own cache line
    head: CachePadded<AtomicUsize>,

    // Consumer-owned: padded to separate cache line
    tail: CachePadded<AtomicUsize>,

    // The buffer slots
    buffer: [UnsafeCell<Option<Task>>; BUFFER_SIZE],

    // Performance statistics (own cache line to avoid false sharing)
    stats: CachePadded<RingBufferStats>,
}

// Safety: RingBuffer handles synchronization via atomics and MPSC logic.
unsafe impl Send for RingBuffer {}
unsafe impl Sync for RingBuffer {}
impl std::panic::RefUnwindSafe for RingBuffer {}

impl Default for RingBuffer {
    fn default() -> Self {
        Self::new()
    }
}

impl RingBuffer {
    pub const fn new() -> Self {
        Self {
            head: CachePadded(AtomicUsize::new(0)),
            tail: CachePadded(AtomicUsize::new(0)),
            buffer: [const { UnsafeCell::new(None) }; BUFFER_SIZE],
            stats: CachePadded(RingBufferStats::new()),
        }
    }

    /// Try to push a task into the buffer. Returns Err if full.
    /// Uses CAS loop to prevent TOCTOU race between capacity check and slot claim.
    #[inline(always)]
    pub fn push(&self, task: Task) -> Result<(), Task> {
        loop {
            let head = self.head.0.load(Ordering::Relaxed);
            let tail = self.tail.0.load(Ordering::Acquire);

            // Check if buffer is full
            if head.wrapping_sub(tail) >= BUFFER_SIZE {
                self.stats.0.push_errors.fetch_add(1, Ordering::Relaxed);
                return Err(task);
            }

            // CAS: atomically claim this slot — only one producer succeeds
            match self.head.0.compare_exchange_weak(
                head,
                head.wrapping_add(1),
                Ordering::AcqRel,
                Ordering::Relaxed,
            ) {
                Ok(_) => {
                    // Safety: We exclusively own this slot via CAS
                    unsafe {
                        let slot = &self.buffer[head & BUFFER_MASK];
                        *slot.get() = Some(task);
                    }

                    // Release fence to ensure task is visible to consumer
                    std::sync::atomic::fence(Ordering::Release);

                    // Update statistics
                    self.stats.0.pushes.fetch_add(1, Ordering::Relaxed);
                    let depth = head.wrapping_sub(tail) + 1;
                    self.stats
                        .0
                        .max_depth
                        .fetch_max(depth as u64, Ordering::Relaxed);

                    return Ok(());
                }
                Err(_) => core::hint::spin_loop(),
            }
        }
    }

    /// Pop a task from the buffer. Only the Consumer (Worker Thread) calls this.
    /// Spins until the producer finishes writing the slot value before advancing tail.
    #[inline(always)]
    pub fn pop(&self) -> Option<Task> {
        let tail = self.tail.0.load(Ordering::Relaxed);
        let head = self.head.0.load(Ordering::Acquire);

        // Fast path: empty check (most common case during low load)
        if tail == head {
            return None;
        }

        // Spin until the producer finishes writing the slot.
        // This handles the window where head was CAS'd but value not yet stored.
        loop {
            let task = unsafe {
                let slot = &self.buffer[tail & BUFFER_MASK];
                (&mut *slot.get()).take()
            };
            if let Some(task) = task {
                self.tail.0.store(tail.wrapping_add(1), Ordering::Release);
                self.stats.0.pops.fetch_add(1, Ordering::Relaxed);
                return Some(task);
            }
            core::hint::spin_loop();
        }
    }

    /// Get current buffer depth
    pub fn depth(&self) -> usize {
        let head = self.head.0.load(Ordering::Relaxed);
        let tail = self.tail.0.load(Ordering::Relaxed);
        head.wrapping_sub(tail)
    }

    /// Get performance statistics
    pub fn stats(&self) -> (u64, u64, u64, u64) {
        (
            self.stats.0.pushes.load(Ordering::Relaxed),
            self.stats.0.pops.load(Ordering::Relaxed),
            self.stats.0.push_errors.load(Ordering::Relaxed),
            self.stats.0.max_depth.load(Ordering::Relaxed),
        )
    }

    /// Batch pop optimization: try to pop multiple tasks at once
    /// Reduces atomic operation overhead
    #[inline(always)]
    pub fn pop_batch(&self, batch: &mut Vec<Task>, max: usize) -> usize {
        let mut count = 0;
        let mut tail = self.tail.0.load(Ordering::Relaxed);
        let head = self.head.0.load(Ordering::Acquire);

        while count < max && tail != head {
            unsafe {
                let slot = &self.buffer[tail & BUFFER_MASK];
                if let Some(task) = (&mut *slot.get()).take() {
                    batch.push(task);
                    tail = tail.wrapping_add(1);
                    count += 1;
                } else {
                    break;
                }
            }
        }

        if count > 0 {
            self.tail.0.store(tail, Ordering::Release);
        }

        count
    }
}

/// Helper for static initialization
pub struct RingBufferStore {
    inner: UnsafeCell<Option<RingBuffer>>,
    initialized: std::sync::atomic::AtomicBool,
}

impl Default for RingBufferStore {
    fn default() -> Self {
        Self::new()
    }
}

impl RingBufferStore {
    #[allow(clippy::large_stack_frames)] // const fn for static init — never on runtime stack
    pub const fn new() -> Self {
        Self {
            inner: UnsafeCell::new(None),
            initialized: std::sync::atomic::AtomicBool::new(false),
        }
    }

    pub fn get(&self) -> Option<&RingBuffer> {
        if !self.initialized.load(Ordering::Acquire) {
            // Lazy init logic here (simplified)
            return None;
        }
        unsafe { (&*self.inner.get()).as_ref() }
    }
}
