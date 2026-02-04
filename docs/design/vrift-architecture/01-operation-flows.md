# vrift: Operation Flows

This document details the step-by-step execution flow of key operations in vrift, from the perspective of the client (e.g., rustc) and the system.

---

## 1. Metadata Operations (`stat`)

**Goal**: Sub-100ns latency.

### 1. Operation Classification (The All-Fast Architecture)

*   **Data Plane (Write)**: Local Staging File (Native FS).
    *   **Cost**: Native Page Cache Throughput.
*   **Control Plane (Commit)**: `close`.
    *   **Mechanism**: UDS Path Handover.
    *   **Cost**: One Syscall per file.

### 2. Detailed Flows

#### 2.1 Staging Open (`open`)
1.  **Client**: `open("main.o", O_WRONLY)`
2.  **InceptionLayer**: Redirects to `.vrift/staging/pid_xxx/fd_yyy.tmp`.
3.  **Return**: Returns Real FD to temp file. **Zero IPC**.

#### 2.2 Native Write (`write`)
1.  **Client**: `write(fd, buf)`
2.  **Kernel**: Writes to Page Cache (Local Staging File).
2.  **InceptionLayer**: Intercepts syscall.
3.  **InceptionLayer**: Queries VDir (Shared Memory Index).
    *   **Hit**: Returns `struct stat` from memory. (Latency: ~50ns)
    *   **Miss**: Falls back to real filesystem. (Latency: ~2µs)

**Architecture Note**: No IPC. No Lock (Wait-free read).

---

## 2. Read Operations (`open` + `read`)

**Goal**: Zero-Copy access to content.

### Flow

1.  **Client**: `open("src/main.rs", O_RDONLY)`
2.  **InceptionLayer**: Intercepts.
3.  **InceptionLayer**: Lookups VDir.
    *   **Metadata**: Gets CAS Hash `abcd...`.
4.  **InceptionLayer**: Checks L2 CAS Pool (Shared Memory).
    *   **Hit**: Returns pointer to shared memory blob.
    *   **Miss**: Maps L3 CAS File (`~/.vrift/cas/abcd...`).
5.  **Client**: `read(fd, buf, len)`
6.  **InceptionLayer**: `memcpy` from CAS ptr to `buf`.

---

## 3. Write Operations (`write`)

**Goal**: Non-blocking ingestion.

### Flow

1.  **Client**: `open("target/main.o", O_WRONLY)`
    *   InceptionLayer buffers metadata.
2.  **Client**: `write(fd, buf)`
    *   InceptionLayer buffers data in process memory.
### 2.3 `close(fd)`
1.  **InceptionLayer**: Sends UDS Command: `COMMIT { path: "main.o", staging_path: "..." }`.
2.  **vdir_d**:
    *   **Action**: `ioctl(FICLONERANGE)` or `link()` to promote staging file to CAS.
    *   **Ack**: Returns status.
3.  **InceptionLayer**: Unlinks staging file (cleanup).
4.  **Return**: Returns `0`.

### Server Background Flow

1.  **Server**: Receives IPC.
2.  **Server**: Computes Hash (BLAKE3).
3.  **Server**: Writes to CAS (Dedup).
4.  **Server**: Updates VDir.

---

[End of original document structure]
