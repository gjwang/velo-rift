# vrift Write Path: The Global Shared Memory Data Plane

## Overview: The "Memory-First" Architecture

**The Challenge**: How to handle hundreds of concurrent writes (e.g., `make -j 128`) entirely in memory without hitting disk IO limitations?

**The Solution**: **Staging Area + Atomic Handover**.
Instead of streaming data through memory buffers, we use the OS's native filesystem as a high-performance staging area.

**Mechanism**:
1.  **Staging**: InceptionLayer writes to a private temporary file (e.g., `.vrift/staging/pid_123/obj.o`).
2.  **Handover**: On `close()`, InceptionLayer passes the path to `vdir_d` via UDS.
3.  **Ingest**: `vdir_d` promotes the file to CAS using **Zero-Copy ReFLINK** (CloneFile/cp --reflink) or Hardlink.

**Key Metrics**:
- **Throughput**: Native FS speed (Page Cache backed).
- **Memory**: Managed by OS (No OOM risk).
- **Concurrency**: Lock-free (Private staging files).

---

## Phase 1: Client-Side Write (The Shared Memory Producer)

### Step 1.1: `open()` - Allocating the Slab

```c
// Global Pool: /dev/shm/vrift_data_pool (e.g., 4GB)
// Mapped into every Client's address space.

int vrift_open_write(const char *path, bool is_small) {
    if (is_small) {
        // Mode A: Shared Memory (The "Hyper-Loop")
        // 1. Atomically allocate a chunk from Global Pool
        //    (Bump pointer or Free List)
        ShmChunk *chunk = shm_alloc(ESTIMATED_SIZE);
        return create_virtual_fd(chunk);
    } else {
        // Mode B: Native Passthrough (Linkers/Large Mmap)
        return real_open(path, ...);
    }
}
```

### Step 1.2: `write()` - Zero-Copy Ingestion

```c
ssize_t vrift_write(int vfd, void *buf, size_t len) {
    // 1. Direct Memcpy to Shared Memory
    //    Client writes directly to Server's visible memory!
    memcpy(vfd->chunk_ptr + offset, buf, len);
    
    // 2. No Kernel transition, no Disk I/O.
    return len;
}
```

### Step 1.3: `close()` - The Non-Blocking Handover

```c
int vrift_close(int vfd) {
    // 1. Send "Pointer" to Server (IPC)
    //    "I wrote 50KB at Offset 0xABCD in the Pool."
    ipc_send_commit_msg(vfd->chunk_offset, vfd->length, hash(path));
    
    // 2. Return instantly.
    return 0;
}
```

*Efficiency*: Data moved from Client to Server with **Zero Copies** (Same physical RAM pages).

---

## Phase 2: Server-Side Ingestion (The Memory Processor)

Server receives hundreds of IPC messages per second.

1.  **Direct Memory Access**: Server reads the data at `Pool + Offset`.
2.  **Parallel Hashing**: Thread pool computes Hash of the memory chunk.
3.  **Dedup Check (The "Disk Eraser")**:
    *   If Hash exists in CAS: **Discard data**. Mark chunk as free.
    *   **Result**: The file **NEVER** touched the disk. Pure memory lifecycle.
4.  **Persistence (Lazy)**:
    *   If Hash is NEW: Async write Shm Chunk -> Disk CAS.
    *   (Optional): Spill to disk only if Pool > 80% usage.

---

## Phase 3: Handling Overflow (The Safety Valve)

**What if 4GB Pool is full?**
1.  **Backpressure**: `shm_alloc` returns NULL.
2.  **Fallback**: Client automatically switches to **Mode C (Local Staging File)**.
    *   Degrades gracefully from "In-Memory" to "Buffered Disk".

---

## Summary of the "Memory-First" Flow

## Summary of the "Staging" Flow

1.  **Compiler**: Writes `.o` to `.vrift/staging/...` (Native Speed).
2.  **Handover**: `close()` -> UDS Commit.
3.  **Server**: `link()` / `reflink()` to CAS. Zero Data Copy.
4.  **Dedup**: If duplicate, unlink staging file.
    - **Disk Writes**: 0 bytes.
    - **Latency**: Microseconds.
    - **Throughput**: Bus speed.

| Feature | RingBuffer (Local) | Shared Memory Data Plane (Final) |
| :--- | :--- | :--- |
| **Data Locality** | Local Process | **Global (Start in Shm)** 🏆 |
| **Handover** | Copy/Flush to Disk | **Zero-Copy Pointer Pass** 🏆 |
| **Concurrent IO** | Limited by threads | **Unlimited (Lock-free)** |
| **Dedup Savings** | Saves Disk Space | **Saves Disk IO Bandwidth** 🏆 |

This answers "How to support hundreds of files almost all in memory".
