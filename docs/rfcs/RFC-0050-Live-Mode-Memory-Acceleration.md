# RFC-0050: Live Mode Memory-Tiered Acceleration

## Summary
This RFC proposes a `--live` mode for Velo Rift that aggressively hosts file I/O in memory, eliminating disk latency for build-intensive workflows. The goal is to transform Velo Rift from a "smart cache" into a **pure in-memory build accelerator**.

## Motivation
Modern compilers (rustc, clang) are CPU-bound in theory, but in practice, they are often **I/O-bound** due to:
1. **Metadata storms**: `stat()` on thousands of headers/sources.
2. **Small file writes**: Generating thousands of `.o`, `.rlib`, `.d` files.
3. **Random read patterns**: Linkers reading symbol tables from scattered `.o` files.

By hosting these operations in a **user-space memory tier**, we can:
- Reduce syscall overhead by 90%+.
- Eliminate disk latency entirely for intermediate artifacts.
- Convert random I/O into sequential memory access.

---

## Design

### 1. Configurable Memory Budget
```toml
# velo.toml
[live]
max_memory = "8GB"  # User sets max RAM for Velo buffer
aggressive_paths = ["target/", "node_modules/", "build/"]
```
- **`max_memory`**: More memory = more files stay in RAM. Less memory = earlier eviction/flushing.
- **`aggressive_paths`**: Directories where `--live` mode applies full memory hosting.

### 2. I/O Interception Flow
```
┌────────────────────────────────────────────────────────────────┐
│  Compiler: write("target/debug/deps/foo.o", data)              │
│                          │                                     │
│                          ▼                                     │
│  vrift-shim: Intercept write()                                 │
│    ├── Path in aggressive_paths? YES                           │
│    ├── Allocate buffer in Daemon SharedMemory                  │
│    ├── memcpy(data -> buffer)                                  │
│    └── Return immediately (fd mapped to memory region)         │
│                          │                                     │
│  Compiler: close(fd)                                           │
│    └── Return immediately (no fsync, no kernel)                │
│                          │                                     │
│  ...later...                                                   │
│  Linker: read("target/debug/deps/foo.o")                       │
│    ├── Shim: Found in memory buffer!                           │
│    └── Return data directly (zero disk I/O)                    │
│                          │                                     │
│  vrift-daemon (background, low priority):                      │
│    └── Batch flush dirty buffers to CAS when idle              │
└────────────────────────────────────────────────────────────────┘
```

### 3. Eviction & Flush Policy
| Trigger | Action |
| :--- | :--- |
| Memory pressure (>90% `max_memory`) | LRU eviction: Flush oldest buffers to disk |
| Idle timeout (e.g., 30s no activity) | Async flush all dirty buffers |
| Explicit `v sync` command | Force sync all to disk |
| Process exit / `v unload` | Graceful flush before teardown |

---

## Projected Performance: `cargo build`

### Baseline (HDD/SSD, no Velo)
| Phase | Time | Bottleneck |
| :--- | :--- | :--- |
| Dependency resolution | ~2s | Network/Disk |
| Compilation (parallel) | ~60s | CPU + I/O wait |
| Linking | ~5s | Random read I/O |
| **Total** | **~67s** | |

### With `--live` Mode (8GB buffer)
| Phase | Time | Bottleneck |
| :--- | :--- | :--- |
| Dependency resolution | ~0s (Phantom ingest) | Memory |
| Compilation (parallel) | ~45s | **CPU only** |
| Linking | ~2s | Memory (mmap) |
| **Total** | **~47s** | |

### Estimated Speedup
> **30-50% faster** on typical Rust projects.  
> **2-5x faster** on I/O-heavy monorepos with thousands of crates.

### Extreme Case (Fully RAM-resident, 32GB+ buffer)
If `max_memory` is large enough to hold the entire `target/` directory:
- **Compilation becomes 100% CPU-bound**.
- Speedup approaches theoretical maximum of the hardware.
- On a 16-core M3 Max: `cargo build` for a large project could drop from **120s to 40s**.

---

## Risks & Mitigations
| Risk | Mitigation |
| :--- | :--- |
| Data loss on power failure | Acceptable for `target/`; user explicitly opts in. |
| OOM on small-memory machines | `max_memory` is a hard cap; Daemon respects it. |
| Daemon crash loses data | Use `mmap(MAP_SHARED)` so kernel retains pages. |

---

## Summary: The Velo "Zero-IO" Promise
> With `--live` mode, **the disk disappears**. Every `read()` and `write()` to known build directories becomes a memory operation. The only remaining bottleneck is the CPU itself.

This transforms Velo Rift from a "smarter npm cache" into a **build runtime accelerator** that competes with in-memory distributed build systems like Bazel Remote Execution—but running entirely locally.
