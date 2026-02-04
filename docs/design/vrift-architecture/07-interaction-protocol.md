# Deep Dive: InceptionLayer <-> vdir_d Interaction Protocol

## 1. Design Goal
**Maximize Throughput, Minimize Latency.**
*   **Throughput**: Limited only by memory bandwidth (`memcpy`).
*   **Latency**: Non-blocking for Producer (InceptionLayer) as long as buffer isn't full.
*   **Safety**: Crash-safe. Consumer (`vdir_d`) failure must not crash Producer.

---

## 2. Shared Memory RingBuffer Layout

Each active file write session (`open` -> `write`... -> `close`) allocates a dedicated **SPSC (Single Producer Single Consumer) RingBuffer** in Shared Memory.

### Memory Structure
```c
struct RingBuffer {
    // Cache Line 1: Producer Write State (Written by InceptionLayer)
    alignas(64) atomic_uint64_t write_head; 
    
    // Cache Line 2: Consumer Read State  (Written by vdir_d)
    alignas(64) atomic_uint64_t read_tail;
    
    // Cache Line 3: Control Flags
    alignas(64) atomic_uint32_t flags; // EOF, ERROR, PAUSE
    uint32_t capacity;                 // Power of 2 (e.g., 4MB)
    
    // Data Area (Aligned to Page Size)
    alignas(4096) uint8_t data[];      
};
```
**Why alignment?** To prevent **False Sharing**. Producer only updates `write_head`, Consumer only updates `read_tail`. They sit on different CPU Cache Lines.

---

## 3. Interaction Flow (The "Fast Loop")

### Phase 1: Channel Pooling (Startup)
Instead of creating a RingBuffer per file (which requires a slow UDS Handshake), we use **Channel Pooling**.

1.  **Startup**: InceptionLayer connects to `vdir_d`.
2.  **Pre-Allocation**: Explicitly negotiates N (e.g., 32) **Shared Channels**.
    *   Each Channel = A dedicated RingBuffer (Memfd).
    *   InceptionLayer maps them all.
    *   InceptionLayer adds them to a local **Free Channel Pool**.

### Phase 2: Async Open (Zero Latency)
**User Operation**: `open("main.o", O_WRONLY)`

1.  **Acquire**: InceptionLayer pops a free Channel (RingBuffer) from Local Pool.
2.  **Assign**: InceptionLayer locally assigns `FD 4` -> `Channel #7`.
3.  **Command**: Writes `OP_OPEN { path: "main.o", channel_id: 7 }` to the **Control Ring**.
4.  **Return**: Returns `FD 4` immediately. **Zero Syscall**.

### Phase 3: Streaming Write
**User Operation**: `write(4, buf)`

1.  **Lookup**: Map `FD 4` -> `Channel #7`.
2.  **Stream**: `memcpy` data to RingBuffer #7 (Standard SPSC).

### Phase 4: Completion (In-Band EOF)
**User Operation**: `close(4)`

1.  **EOF**: Atomic Store `channel[7].flags = EOF`.
2.  **Release**: InceptionLayer returns `Channel #7` to Local Free Pool.
3.  **Return**: Returns `0` instantly.

---

## 4. Critical Design Choices

### A. Backpressure Strategy
*   **What if Consumer is slow?** (CPU load high)
*   **Behavior**: Producer (Compiler) **BLOCKS**.
*   **Rationale**: This is standard Kernel behavior (Pipe/Socket buffer full). Prevents OOM. Compiler pauses naturally, giving `vdir_d` CPU time to catch up. Self-regulating system.

### B. Why RingBuffer > Pipe?
*   **Pipe**: Needs Syscall (`write` + `read`) and usually involves kernel-internal copy (or page flipping cost).
*   **Shared RingBuffer**: 
    *   **Zero Syscall** in non-full/non-empty case.
    *   **User-Space Memcpy**.
    *   Modern CPUs optimized for memcpy.

### C. Signaling (EventFD vs Futex)
*   **Futex**: Fastest. User-space check first, syscall only if contention.
*   **Decision**: Use **Futex** on the `head`/`tail` atomic variables directly.

---

## 5. Performance Envelop
*   **Throughput**: 10GB/s+ (Memory Bandwidth saturation).
*   **Latency**: < 1µs (Cache coherency latency).
*   **IPC Overhead**: Only when buffer fills/empties. For a 100MB file and 4MB buffer, we signal ~25 times. Negligible.
