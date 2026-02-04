# vrift Write Path: Staging Area & Zero-Copy Ingestion

## 1. The Strategy: "Native Staging, Atomic Handover"

Instead of complex Shared Memory RingBuffers, we leverage the OS's native filesystem capabilities for the Write Path.

**Core Philosophy**: 
*   **Write**: Use the OS Page Cache (Native Speed).
*   **Ingest**: Use File System Metadata Operations (Zero-Copy).
*   **Consistency**: Explicit "Dirty" marking during the modification window.

---

## 2. Phase 1: Client-Side Staging (InceptionLayer)

### Step 1: Open & Mark Dirty
When Client calls `open("main.o", O_WRONLY)`:
1.  **Mark Dirty**: InceptionLayer flips a `DIRTY` bit for "main.o" in the Shared Memory Index.
    *   *Effect*: Any subsequent `stat/read` from *any* process will be forced to check the Staging Area (Real Path).
2.  **Redirect**: The FD returned to the client actually points to a privately owned temporary file:
    *   Path: `.vrift/staging/<pid>/<fd>_<timestamp>.tmp`

### Step 2: Native Write
*   **Mechanism**: Client calls standard `write()`.
*   **Performance**: Data goes into OS Page Cache. No IPC overhead. No buffer management overhead.

### Step 3: Close & Commit
When Client calls `close()`:
1.  **Flush**: `fsync()` (Optional, usually we rely on OS lazy writeback).
2.  **Handover**: InceptionLayer sends a **UDS Message** to `vdir_d`:
    ```rust
    CMD_COMMIT {
        virtual_path: "main.o",
        staging_path: ".vrift/staging/123/456.tmp",
        size: 10240,
        mtime: ...
    }
    ```
3.  **Wait**: InceptionLayer waits for `ACK` from `vdir_d`.

---

## 3. Phase 2: Server-Side Ingestion (`vdir_d`)

Upon receiving `CMD_COMMIT`:

### Step 1: Ingestion (Zero-Copy)
`vdir_d` promotes the Staging File to the Content-Addressable Storage (CAS).

*   **Method A: ReFLINK (Cow)**
    `ioctl(FICLONERANGE, src=staging, dst=cas/hash)`
    *   *Cost*: O(1) Metadata update. No data copy.
*   **Method B: Hardlink**
    `link(src=staging, dst=cas/hash)`
    *   *Cost*: O(1).
*   **Method C: Rename (If Single Reference)**
    `rename(src=staging, dst=cas/hash)`

### Step 2: Index Update & Clean
1.  **Update Index**: Updates the VDir Entry for "main.o" to point to the new CAS Hash.
2.  **Clear Dirty**: Clears the `DIRTY` bit.
    *   *Effect*: Future `stat/read` will hit the fast VDir Index again.
3.  **Ack**: Replies `OK` to InceptionLayer.

---

## 4. Consistency Model (The "Dirty Bit" Guarantee)

**Constraint**: Modifications must be visible immediately to other processes.

| State | Reader Behavior |
| :--- | :--- |
| **Clean** | Read from VDir Index / Shared Memory (Fast). |
| **Dirty** (Writing) | **Must** read from `.vrift/staging/...` (Real Path). |

*   **Crash Safety**: If InceptionLayer crashes while `DIRTY`:
    *   The `DIRTY` bit remains.
    *   `vdir_d` (Watchdog) detects the crash (Socket HUP).
    *   `vdir_d` rolls back the State (reverts to previous Hash) and clears `DIRTY`.
    *   The partial Staging File is garbage collected.

---

## 5. Performance Characteristics

*   **Throughput**: Limited only by Disk Bandwidth (or Memory Bandwidth if fits in Page Cache).
*   **Latency**: 
    *   `open`: ~3µs (Local syscall).
    *   `write`: ~10ns (Page Cache).
    *   `close`: ~20µs (UDS Handover).
*   **Memory Overhead**: Minimal (OS Managed).
