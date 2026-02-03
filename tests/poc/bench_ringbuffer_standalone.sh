#!/bin/bash
# Quick standalone benchmark

cat > /tmp/bench_rb.rs << 'EOF'
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Instant;
use std::cell::UnsafeCell;

const BUFFER_SIZE: usize = 4096;
const BUFFER_MASK: usize = BUFFER_SIZE - 1;

struct CustomRingBuffer {
    head: AtomicUsize,
    tail: AtomicUsize,
    buffer: [UnsafeCell<Option<usize>>; BUFFER_SIZE],
}

unsafe impl Send for CustomRingBuffer {}
unsafe impl Sync for CustomRingBuffer {}

impl CustomRingBuffer {
    fn new() -> Self {
        Self {
            head: AtomicUsize::new(0),
            tail: AtomicUsize::new(0),
            buffer: [const { UnsafeCell::new(None) }; BUFFER_SIZE],
        }
    }

    fn push(&self, value: usize) -> Result<(), ()> {
        let head = self.head.load(Ordering::Relaxed);
        let tail = self.tail.load(Ordering::Acquire);

        if head.wrapping_sub(tail) >= BUFFER_SIZE {
            return Err(());
        }

        let pos = self.head.fetch_add(1, Ordering::Relaxed);
        unsafe {
            *self.buffer[pos & BUFFER_MASK].get() = Some(value);
        }
        Ok(())
    }

    fn pop(&self) -> Option<usize> {
        let tail = self.tail.load(Ordering::Relaxed);
        let head = self.head.load(Ordering::Acquire);

        if tail == head {
            return None;
        }

        let value = unsafe {
            (&mut *self.buffer[tail & BUFFER_MASK].get()).take()
        };

        if value.is_some() {
            self.tail.store(tail.wrapping_add(1), Ordering::Release);
        }
        value
    }
}

fn main() {
    const ITERATIONS: usize = 5_000_000;
    const PRODUCERS: usize = 4;

    println!("=== Custom MPSC RingBuffer Benchmark ===");
    println!("Iterations: {}, Producers: {}\n", ITERATIONS, PRODUCERS);

    let buffer = Arc::new(CustomRingBuffer::new());
    let done = Arc::new(AtomicUsize::new(0));
    let start = Instant::now();

    // Spawn producers
    let mut handles = vec![];
    for _ in 0..PRODUCERS {
        let buf = buffer.clone();
        let dn = done.clone();
        
        handles.push(std::thread::spawn(move || {
            let per_thread = ITERATIONS / PRODUCERS;
            for i in 0..per_thread {
                while buf.push(i).is_err() {
                    std::hint::spin_loop();
                }
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
            while consumed < ITERATIONS {
                if buf.pop().is_some() {
                    consumed += 1;
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

    println!("Time: {:.3}s", elapsed.as_secs_f64());
    println!("Throughput: {:.2} M ops/s", ITERATIONS as f64 / elapsed.as_secs_f64() / 1_000_000.0);
    println!("Avg latency: {:.1} ns/op", elapsed.as_nanos() as f64 / ITERATIONS as f64);
    println!("Consumed: {}", consumed);
}
EOF

rustc -O /tmp/bench_rb.rs -o /tmp/bench_rb && /tmp/bench_rb
