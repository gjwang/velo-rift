# RFC-0045: VFS Performance Profiling

> **Status**: Draft  
> **Author**: VFS Expert Review  
> **Created**: 2026-02-01  
> **Priority**: P2

## Overview

This RFC proposes a built-in performance profiling system for Velo Rift VFS that records runtime statistics for debugging, optimization, and observability.

## Motivation

- **No visibility** into VFS overhead during builds
- **Cannot identify** hot paths or bottlenecks
- **Hard to measure** cache efficiency and I/O savings
- **Need data** for future optimization decisions

## Goals

1. Zero-overhead when disabled (production default)
2. Minimal overhead (< 1%) when enabled
3. Real-time access to statistics
4. Export for analysis and comparison

## Non-Goals

- Full tracing (use perf/dtrace for that)
- Distributed profiling
- Automatic optimization

---

## Design

### Architecture

```
┌──────────────────────────────────────────────────────┐
│                    vrift-shim                        │
│  ┌────────────────────────────────────────────────┐  │
│  │           VriftProfile (AtomicU64s)            │  │
│  │  stat_calls | open_calls | mmap_calls | ...    │  │
│  └────────────────────────────────────────────────┘  │
│                         │                            │
│                         ▼                            │
│  ┌────────────────────────────────────────────────┐  │
│  │         Shared Memory (mmap'd file)            │  │
│  │              /tmp/vrift-profile-<pid>          │  │
│  └────────────────────────────────────────────────┘  │
└───────────────────────│──────────────────────────────┘
                        │
         ┌──────────────┴──────────────┐
         ▼                             ▼
┌─────────────────┐          ┌─────────────────┐
│   vrift CLI     │          │  External Tools │
│  profile show   │          │  (grafana, etc) │
└─────────────────┘          └─────────────────┘
```

### Profile Structure

```rust
#[repr(C)]
pub struct VriftProfile {
    // Header
    magic: u32,           // 0x56524654 ("VRFT")
    version: u32,         // Profile format version
    start_time_ns: u64,   // Session start timestamp
    
    // Syscall Counters
    stat_calls: AtomicU64,
    fstat_calls: AtomicU64,
    lstat_calls: AtomicU64,
    open_calls: AtomicU64,
    close_calls: AtomicU64,
    read_calls: AtomicU64,
    write_calls: AtomicU64,
    mmap_calls: AtomicU64,
    opendir_calls: AtomicU64,
    readdir_calls: AtomicU64,
    readlink_calls: AtomicU64,
    dlopen_calls: AtomicU64,
    
    // Latency (cumulative nanoseconds)
    stat_latency_ns: AtomicU64,
    open_latency_ns: AtomicU64,
    mmap_latency_ns: AtomicU64,
    
    // Cache Statistics
    manifest_hits: AtomicU64,
    manifest_misses: AtomicU64,
    bloom_rejects: AtomicU64,     // Fast-path rejections
    cas_hits: AtomicU64,
    cas_misses: AtomicU64,
    
    // I/O Statistics
    bytes_read: AtomicU64,
    bytes_written: AtomicU64,
    cow_copies: AtomicU64,        // Copy-on-write events
    dedup_savings: AtomicU64,     // Bytes saved by dedup
    
    // ★ VFS CONTRIBUTION (Key Metrics)
    vfs_handled: AtomicU64,       // Syscalls fully handled by VFS
    vfs_passthrough: AtomicU64,   // Syscalls passed to real FS
    time_saved_ns: AtomicU64,     // Estimated time saved (nanoseconds)
    original_size: AtomicU64,     // Original file sizes (before dedup)
    
    // Error Counters
    enoent_count: AtomicU64,      // File not found
    eacces_count: AtomicU64,      // Permission denied
    ipc_errors: AtomicU64,        // Daemon communication errors
}
```

### CLI Commands

```bash
# Enable profiling for a session
vrift profile start

# Show real-time statistics
vrift profile show

# Output:
# ┌─────────────────────────────────────────────────┐
# │  vrift profile                                  │
# │  ─────────────────────────────────────────────  │
# │  Session: 2026-02-01 13:59:06                   │
# │  Duration: 45.2s                                │
# │                                                 │
# │  Syscall Stats:                                 │
# │  ├─ stat      12,345 calls   (8.2ms total)     │
# │  ├─ open       3,210 calls   (12.1ms total)    │
# │  ├─ mmap         456 calls   (2.3ms total)     │
# │  └─ readdir      890 calls   (1.5ms total)     │
# │                                                 │
# │  Cache Stats:                                   │
# │  ├─ Manifest Hits:    95.2%                    │
# │  ├─ CAS Hits:         99.8%                    │
# │  └─ Bloom Rejects:    87.3%                    │
# │                                                 │
# │  ═══════════════════════════════════════════   │
# │  ★ VFS CONTRIBUTION (Vrift Value)              │
# │  ═══════════════════════════════════════════   │
# │                                                 │
# │  Intercepted vs Passthrough:                   │
# │  ├─ VFS Handled:     8,234 (65.2%)  ← Vrift   │
# │  ├─ Passthrough:     4,392 (34.8%)            │
# │  └─ Total Syscalls: 12,626                     │
# │                                                 │
# │  Time Saved:                                   │
# │  ├─ Avoided Disk I/O:    12.3s                │
# │  ├─ Cache Hit Speedup:    8.7s                │
# │  └─ Total Saved:         21.0s (46%)          │
# │                                                 │
# │  Disk Saved (Dedup):                           │
# │  ├─ Original Size:       2.1 GB               │
# │  ├─ Actual Stored:     890 MB                 │
# │  └─ Saved:             1.2 GB (57%)           │
# │  ═══════════════════════════════════════════   │
# │                                                 │
# │  I/O Stats:                                     │
# │  ├─ Bytes Read:       1.2 GB                   │
# │  ├─ Bytes Written:    45 MB (CoW)              │
# │  └─ Disk Saved:       890 MB (dedup)           │
# └─────────────────────────────────────────────────┘

# Export to JSON for analysis
vrift profile export > profile.json

# Reset counters
vrift profile reset

# Disable profiling
vrift profile stop
```

### Environment Variable Control

```bash
# Enable profiling via env var
VRIFT_PROFILE=1 cargo build

# Set profile output path
VRIFT_PROFILE_PATH=/tmp/my-profile.bin cargo build
```

---

## Implementation Plan

### Phase 1: Core Counters (MVP)

1. Add `VriftProfile` struct with atomic counters
2. Increment counters in shim syscall implementations
3. Add `vrift profile show` CLI command
4. Store profile in shared memory file

### Phase 2: Latency Tracking

1. Add timestamp capture at syscall entry/exit
2. Accumulate latency in atomic counters
3. Calculate averages and percentiles

### Phase 3: Advanced Analytics

1. Add histogram support for latency distribution
2. Add hot path detection (most called paths)
3. Add export to Prometheus/Grafana format

---

## Overhead Analysis

| Operation | Overhead (enabled) | Overhead (disabled) |
|-----------|-------------------|---------------------|
| Counter increment | ~5ns (atomic) | 0 |
| Timestamp capture | ~20ns (CLOCK_MONOTONIC) | 0 |
| Memory | 4KB shared memory | 0 |

**Expected total overhead: < 0.5%** for typical builds.

---

## Alternatives Considered

| Alternative | Pros | Cons |
|-------------|------|------|
| Log file | Simple | I/O overhead, parsing needed |
| Daemon aggregation | Centralized | IPC overhead |
| eBPF | Zero modification | Complex, Linux only |

---

## Testing

1. **Unit test**: Verify counter increments
2. **Integration test**: Verify CLI output format
3. **Performance test**: Verify < 1% overhead
4. **Regression test**: `test_profile_overhead.sh`

---

## Open Questions

1. Should profile persist across daemon restarts?
2. Should we support per-process or global profiles?
3. What histogram bucket sizes for latency?

---

## Future Enhancements

### 🎨 Visualization Expert Recommendations

1. **Real-time Dashboard**
   ```bash
   vrift profile --live   # htop-style live updating UI
   ```

2. **Flame Graph Export**
   ```bash
   vrift profile flamegraph > profile.svg
   ```

3. **Build Progress Bar**
   ```
   Building... ████████░░ 80%
   VFS Contribution: 65% handled | 1.2GB saved
   ```

### 🎯 UX Expert Recommendations

1. **Auto Summary (on build completion)**
   ```
   ✅ Build complete in 45.2s
   ★ Vrift saved 21.0s (46% faster) and 1.2GB disk
   ```

2. **Color Coding**
   - 🟢 High efficiency (>70% VFS handled)
   - 🟡 Medium (30-70%)
   - 🔴 Low (<30%)

3. **One-click Compare**
   ```bash
   vrift profile compare build1.json build2.json
   ```

### 📣 Marketing Expert Recommendations

1. **"Saved" Emphasis Language**
   ```
   "Your build saved 21 seconds thanks to Vrift cache"
   "Vrift deduplicated 1.2GB of dependencies"
   ```

2. **Shareable Badge**
   ```markdown
   ![Vrift Stats](https://vrift.io/badge/user/project)
   ```
   ```
   Build: 45s | Saved: 21s | Dedup: 57%
   ```

3. **Weekly Report Email**
   ```
   This week Vrift saved you:
   - 2.3 hours of build time
   - 15GB of disk space
   ```

---

## References

- [perf-profile design](https://perf.wiki.kernel.org)
- [Prometheus metrics](https://prometheus.io/docs/concepts/metric_types/)
