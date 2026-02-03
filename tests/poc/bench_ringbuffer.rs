use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Instant;

// Import crossbeam for comparison
use crossbeam::queue::ArrayQueue;

fn main() {
    const ITERATIONS: usize = 10_000_000;
    const PRODUCERS: usize = 4;

    println!("=== RingBuffer Performance Benchmark ===");
    println!("Iterations: {}", ITERATIONS);
    println!("Producers: {}", PRODUCERS);
    println!();

    // Test 1: Custom MPSC RingBuffer
    println!("[1] Custom MPSC RingBuffer:");
    bench_custom_ringbuffer(ITERATIONS, PRODUCERS);
    println!();

    // Test 2: Crossbeam ArrayQueue
    println!("[2] Crossbeam ArrayQueue:");
    bench_crossbeam(ITERATIONS, PRODUCERS);
    println!();
}

// Simplified version of our custom RingBuffer for testing
mod custom {
    use std::cell::UnsafeCell;
    use std::sync::atomic::{AtomicUsize, Ordering};

    const BUFFER_SIZE: usize = 4096;
    const BUFFER_MASK: usize = BUFFER_SIZE - 1;

    pub struct RingBuffer {
        head: AtomicUsize,
        tail: AtomicUsize,
        buffer: [UnsafeCell<Option<usize>>; BUFFER_SIZE],
    }

    unsafe impl Send for RingBuffer {}
    unsafe impl Sync for RingBuffer {}

    impl RingBuffer {
        pub fn new() -> Self {
            Self {
                head: AtomicUsize::new(0),
                tail: AtomicUsize::new(0),
                buffer: [const { UnsafeCell::new(None) }; BUFFER_SIZE],
            }
        }

        pub fn push(&self, value: usize) -> Result<(), usize> {
            let head = self.head.load(Ordering::Relaxed);
            let tail = self.tail.load(Ordering::Acquire);

            if head.wrapping_sub(tail) >= BUFFER_SIZE {
                return Err(value);
            }

            let pos = self.head.fetch_add(1, Ordering::Relaxed);

            unsafe {
                let slot = &self.buffer[pos & BUFFER_MASK];
                *slot.get() = Some(value);
            }

            Ok(())
        }

        pub fn pop(&self) -> Option<usize> {
            let tail = self.tail.load(Ordering::Relaxed);
            let head = self.head.load(Ordering::Acquire);

            if tail == head {
                return None;
            }

            let value = unsafe {
                let slot = &self.buffer[tail & BUFFER_MASK];
                (&mut *slot.get()).take()
            };

            if value.is_some() {
                self.tail.store(tail.wrapping_add(1), Ordering::Release);
            }

            value
        }
    }
}

fn bench_custom_ringbuffer(iterations: usize, num_producers: usize) {
    let buffer = Arc::new(custom::RingBuffer::new());
    let counter = Arc::new(AtomicUsize::new(0));
    let done = Arc::new(AtomicUsize::new(0));

    let start = Instant::now();

    // Spawn producers
    let mut handles = vec![];
    for _ in 0..num_producers {
        let buf = buffer.clone();
        let cnt = counter.clone();
        let dn = done.clone();
        
        handles.push(std::thread::spawn(move || {
            let per_thread = iterations / num_producers;
            for i in 0..per_thread {
                while buf.push(i).is_err() {
                    std::hint::spin_loop();
                }
                cnt.fetch_add(1, Ordering::Relaxed);
            }
            dn.fetch_add(1, Ordering::Relaxed);
        }));
    }

    // Consumer
    let consumer = {
        let buf = buffer.clone();
        let dn = done.clone();
        std::thread::spawn(move || {
            let mut consumed = 0;
            while consumed < iterations || dn.load(Ordering::Relaxed) < num_producers {
                if buf.pop().is_some() {
                    consumed += 1;
                } else {
                    std::hint::spin_loop();
                }
            }
            consumed
        })
    };

    for h in handles {
        h.join().unwrap();
    }
    let consumed = consumer.join().unwrap();

    let elapsed = start.elapsed();
    println!("  Time: {:.3}s", elapsed.as_secs_f64());
    println!("  Throughput: {:.2} M ops/s", iterations as f64 / elapsed.as_secs_f64() / 1_000_000.0);
    println!("  Avg latency: {:.1} ns/op", elapsed.as_nanos() as f64 / iterations as f64);
    println!("  Consumed: {}", consumed);
}

fn bench_crossbeam(iterations: usize, num_producers: usize) {
    let buffer = Arc::new(ArrayQueue::new(4096));
    let counter = Arc::new(AtomicUsize::new(0));
    let done = Arc::new(AtomicUsize::new(0));

    let start = Instant::now();

    // Spawn producers
    let mut handles = vec![];
    for _ in 0..num_producers {
        let buf = buffer.clone();
        let cnt = counter.clone();
        let dn = done.clone();
        
        handles.push(std::thread::spawn(move || {
            let per_thread = iterations / num_producers;
            for i in 0..per_thread {
                while buf.push(i).is_err() {
                    std::hint::spin_loop();
                }
                cnt.fetch_add(1, Ordering::Relaxed);
            }
            dn.fetch_add(1, Ordering::Relaxed);
        }));
    }

    // Consumer
    let consumer = {
        let buf = buffer.clone();
        let dn = done.clone();
        std::thread::spawn(move || {
            let mut consumed = 0;
            while consumed < iterations || dn.load(Ordering::Relaxed) < num_producers {
                if buf.pop().is_some() {
                    consumed += 1;
                } else {
                    std::hint::spin_loop();
                }
            }
            consumed
        })
    };

    for h in handles {
        h.join().unwrap();
    }
    let consumed = consumer.join().unwrap();

    let elapsed = start.elapsed();
    println!("  Time: {:.3}s", elapsed.as_secs_f64());
    println!("  Throughput: {:.2} M ops/s", iterations as f64 / elapsed.as_secs_f64() / 1_000_000.0);
    println!("  Avg latency: {:.1} ns/op", elapsed.as_nanos() as f64 / iterations as f64);
    println!("  Consumed: {}", consumed);
}
