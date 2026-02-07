#!/bin/bash
# ==============================================================================
# Benchmark: Ring Buffer Standalone Throughput
# ==============================================================================
# Measures the push/pop throughput of the MPSC ring buffer in isolation,
# without IPC or daemon overhead. Validates lock-free performance under
# various contention levels.
#
# Usage:
#   ./bench_ringbuffer_standalone.sh
#   ./bench_ringbuffer_standalone.sh --release    (default: release mode)
#   ./bench_ringbuffer_standalone.sh --debug      (debug mode - slower)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BUILD_MODE="release"
for arg in "$@"; do
    case "$arg" in
        --debug) BUILD_MODE="debug" ;;
        --release) BUILD_MODE="release" ;;
    esac
done

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║           Ring Buffer Standalone Benchmark                         ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# Create a standalone benchmark binary
BENCH_DIR="$PROJECT_ROOT/target/bench_rb"
mkdir -p "$BENCH_DIR"

BENCH_SRC="$BENCH_DIR/ring_buffer_bench.rs"
BENCH_BIN="$BENCH_DIR/ring_buffer_bench"

cat > "$BENCH_SRC" << 'BENCH_EOF'
//! Standalone Ring Buffer Benchmark
//! Tests MPSC throughput at various producer counts.

use std::cell::UnsafeCell;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering, fence};
use std::sync::{Arc, Barrier};
use std::time::Instant;

// ---- Inline ring buffer (self-contained, no crate dependency) ----

const BUFFER_SIZE: usize = 4096;
const BUFFER_MASK: usize = BUFFER_SIZE - 1;

enum Task {
    Log(u64),
}

#[repr(align(128))]
struct CachePadded<T>(T);

#[repr(align(64))]
struct RingBuffer {
    head: CachePadded<AtomicUsize>,
    tail: CachePadded<AtomicUsize>,
    buffer: [UnsafeCell<Option<Task>>; BUFFER_SIZE],
    pushes: CachePadded<AtomicU64>,
    push_errors: CachePadded<AtomicU64>,
}

unsafe impl Send for RingBuffer {}
unsafe impl Sync for RingBuffer {}

impl RingBuffer {
    fn new() -> Self {
        Self {
            head: CachePadded(AtomicUsize::new(0)),
            tail: CachePadded(AtomicUsize::new(0)),
            buffer: std::array::from_fn(|_| UnsafeCell::new(None)),
            pushes: CachePadded(AtomicU64::new(0)),
            push_errors: CachePadded(AtomicU64::new(0)),
        }
    }

    #[inline(always)]
    fn push(&self, task: Task) -> Result<(), Task> {
        let head = self.head.0.load(Ordering::Relaxed);
        let tail = self.tail.0.load(Ordering::Acquire);
        if head.wrapping_sub(tail) >= BUFFER_SIZE {
            self.push_errors.0.fetch_add(1, Ordering::Relaxed);
            return Err(task);
        }
        let pos = self.head.0.fetch_add(1, Ordering::Relaxed);
        unsafe {
            let slot = &self.buffer[pos & BUFFER_MASK];
            *slot.get() = Some(task);
        }
        fence(Ordering::Release);
        self.pushes.0.fetch_add(1, Ordering::Relaxed);
        Ok(())
    }

    #[inline(always)]
    fn pop(&self) -> Option<Task> {
        let tail = self.tail.0.load(Ordering::Relaxed);
        let head = self.head.0.load(Ordering::Acquire);
        if tail == head {
            return None;
        }
        let task = unsafe {
            let slot = &self.buffer[tail & BUFFER_MASK];
            (&mut *slot.get()).take()
        };
        self.tail.0.store(tail.wrapping_add(1), Ordering::Release);
        task
    }
}

// ---- Benchmark harness ----

fn bench_throughput(num_producers: usize, ops_per_producer: usize) {
    let rb = Arc::new(RingBuffer::new());
    let barrier = Arc::new(Barrier::new(num_producers + 2)); // +1 consumer +1 main
    let consumer_done = Arc::new(std::sync::atomic::AtomicBool::new(false));

    let total_ops = num_producers * ops_per_producer;

    // Consumer thread
    let rb_c = rb.clone();
    let barrier_c = barrier.clone();
    let done_c = consumer_done.clone();
    let consumer = std::thread::spawn(move || {
        let mut consumed = 0u64;
        barrier_c.wait();
        loop {
            if let Some(_task) = rb_c.pop() {
                consumed += 1;
                if consumed >= total_ops as u64 {
                    break;
                }
            } else if done_c.load(Ordering::Relaxed) {
                // Drain remaining
                while rb_c.pop().is_some() {
                    consumed += 1;
                }
                break;
            } else {
                std::hint::spin_loop();
            }
        }
        consumed
    });

    // Producer threads
    let mut producers = Vec::new();
    for _ in 0..num_producers {
        let rb_p = rb.clone();
        let barrier_p = barrier.clone();
        let handle = std::thread::spawn(move || {
            let mut pushed = 0u64;
            let mut retries = 0u64;
            barrier_p.wait();
            for i in 0..ops_per_producer {
                loop {
                    match rb_p.push(Task::Log(i as u64)) {
                        Ok(()) => {
                            pushed += 1;
                            break;
                        }
                        Err(_) => {
                            retries += 1;
                            std::hint::spin_loop();
                        }
                    }
                }
            }
            (pushed, retries)
        });
        producers.push(handle);
    }

    // Start timing
    barrier.wait();
    let start = Instant::now();

    // Wait for producers
    let mut total_pushed = 0u64;
    let mut total_retries = 0u64;
    for p in producers {
        let (pushed, retries) = p.join().unwrap();
        total_pushed += pushed;
        total_retries += retries;
    }
    consumer_done.store(true, Ordering::Relaxed);

    let consumed = consumer.join().unwrap();
    let elapsed = start.elapsed();

    let ops_sec = total_pushed as f64 / elapsed.as_secs_f64();
    let push_errors = rb.push_errors.0.load(Ordering::Relaxed);

    println!(
        "  {:>2}P x {:>7} ops │ {:>10.0} ops/s │ {:>6.2}ms │ consumed={} retries={} backpressure={}",
        num_producers,
        ops_per_producer,
        ops_sec,
        elapsed.as_secs_f64() * 1000.0,
        consumed,
        total_retries,
        push_errors,
    );
}

fn bench_latency(num_producers: usize) {
    let rb = Arc::new(RingBuffer::new());
    let barrier = Arc::new(Barrier::new(2));
    let iterations = 100_000;

    // Pre-warm
    let _ = rb.push(Task::Log(0));
    let _ = rb.pop();

    let rb_p = rb.clone();
    let barrier_p = barrier.clone();

    let producer = std::thread::spawn(move || {
        barrier_p.wait();
        for i in 0..iterations {
            loop {
                match rb_p.push(Task::Log(i)) {
                    Ok(()) => break,
                    Err(_) => std::hint::spin_loop(),
                }
            }
        }
    });

    barrier.wait();
    let start = Instant::now();
    let mut consumed = 0u64;
    while consumed < iterations {
        if rb.pop().is_some() {
            consumed += 1;
        } else {
            std::hint::spin_loop();
        }
    }
    let elapsed = start.elapsed();
    producer.join().unwrap();

    let avg_ns = elapsed.as_nanos() as f64 / consumed as f64;
    println!(
        "  {:>2}P roundtrip    │ {:>10.1} ns/op │ {:>6.2}ms total │ {} ops",
        num_producers, avg_ns, elapsed.as_secs_f64() * 1000.0, consumed
    );
    let _ = num_producers;
}

fn main() {
    println!();
    println!("  Throughput Test (push+pop, varying producer count)");
    println!("  ─────────────────────────────────────────────────────────");

    let ops = 1_000_000;

    bench_throughput(1, ops);
    bench_throughput(2, ops / 2);
    bench_throughput(4, ops / 4);
    bench_throughput(8, ops / 8);
    bench_throughput(16, ops / 16);

    println!();
    println!("  Latency Test (single producer, push→pop roundtrip)");
    println!("  ─────────────────────────────────────────────────────────");

    bench_latency(1);

    println!();

    // Summary
    println!("  Buffer size: {} slots ({} bytes per slot approx)",
        BUFFER_SIZE, std::mem::size_of::<Option<Task>>());
    println!("  Cache padding: 128 bytes (double cache line)");
    println!();
}
BENCH_EOF

# Build the benchmark
echo "🔨 Building benchmark (${BUILD_MODE} mode)..."
BUILD_FLAGS=""
if [ "$BUILD_MODE" = "release" ]; then
    BUILD_FLAGS="--release"
fi

rustc $BENCH_SRC -o "$BENCH_BIN" \
    --edition 2021 \
    $([ "$BUILD_MODE" = "release" ] && echo "-C opt-level=3 -C target-cpu=native" || echo "") \
    2>&1 || {
    echo "❌ Failed to compile benchmark"
    exit 1
}
echo "   ✓ Built"
echo ""

# Run benchmark
echo "📊 Running benchmark..."
echo ""
"$BENCH_BIN"

echo "✅ Benchmark complete"
