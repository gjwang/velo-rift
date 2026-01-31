# Pattern 987: macOS EPERM Remediation

## Problem Statement

On macOS, `hard_link()` fails with `EPERM (Operation not permitted)` when attempting to link files inside **code-signed bundles** such as:

- `.app` packages (e.g., `Chromium.app` from puppeteer)
- `.framework` directories
- XPC Services under `/Contents/XPCServices`

### Root Cause

macOS kernel enforces code signature integrity. A hard link would allow:
1. Multiple inodes pointing to the same signed content
2. Potential for one reference to be modified, breaking signature verification
3. Gatekeeper violations

### Error Example

```
Error: Failed to ingest: node_modules/puppeteer/.local-chromium/mac-1002410/
       chrome-mac/Chromium.app/Contents/Resources/de.lproj/InfoPlist.strings
Caused by: I/O error: Operation not permitted (os error 1)
```

---

## Solution: Tiered Fallback Strategy

**Strategy**: `hard_link → clonefile → copy`

### Tier 1: hard_link (Default)
- **Cost**: O(1), zero-copy
- **Behavior**: Creates second inode reference to same data
- **Limitation**: Fails on code-signed bundles

### Tier 2: clonefile (APFS CoW)
- **Cost**: O(1), zero-copy on APFS
- **Behavior**: Creates independent inode with shared data blocks
- **Advantage**: Works with code-signed files, separate inode
- **Limitation**: Only works on APFS filesystems

### Tier 3: copy (Fallback)
- **Cost**: O(n), full data copy
- **Behavior**: Creates completely independent file
- **Use case**: Last resort when Tier 1 and 2 fail

---

## Implementation

```rust
fn link_or_clone_or_copy(source: &Path, target: &Path) -> io::Result<()> {
    // Tier 1: hard_link
    match fs::hard_link(source, target) {
        Ok(()) => return Ok(()),
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => return Ok(()),
        Err(e) if e.kind() == io::ErrorKind::PermissionDenied => { /* try next */ }
        Err(e) => return Err(e),
    }
    
    // Tier 2: clonefile (APFS)
    if reflink_copy::reflink(source, target).is_ok() {
        return Ok(());
    }
    
    // Tier 3: copy
    fs::copy(source, target)?;
    Ok(())
}
```

---

## Related Issues

| Issue | Scenario | Handling |
|-------|----------|----------|
| **EPERM** | Code-signed bundles | Pattern 987 (this doc) |
| **EXDEV** | Cross-device link | Pattern 986 (copy fallback) |
| **ENOTSUP** | FAT32/exFAT | Same as EPERM |
| **Quarantine bit** | Downloaded files | `xattr -d` or accept |

---

## Test Case

`crates/vrift-cas/tests/test_macos_eperm.rs`

```bash
# Run with puppeteer installed
cargo test --package vrift-cas --test test_macos_eperm -- --ignored
```

---

## References

- Apple Developer: [Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/)
- APFS: [clonefile(2)](https://www.manpagez.com/man/2/clonefile/)
- Crate: [reflink-copy](https://crates.io/crates/reflink-copy)

---

# Appendix: CAS Design for .app Bundles

## Design Question

For directories like `Chromium.app` (hundreds of MB, thousands of files), how should CAS handle them?

| Approach | Description |
|----------|-------------|
| **Atomic Blob** | Treat entire .app as single indexed unit |
| **Granular Ingestion** | Digest each internal file separately |

## Recommended: Granular Ingestion ("Logical Whole, Physical Discrete")

This is the approach used by pnpm and high-performance VFS systems.

### Why Granular?

| Aspect | Atomic Blob | Granular (Recommended) |
|--------|-------------|------------------------|
| **Dedup** | ❌ Poor (300MB on minor update) | ✅ Excellent (share unchanged files) |
| **Deployment** | ❌ Extract entire package | ✅ On-demand file access |
| **Index Size** | ✅ Single record | ❌ Many records |
| **Atomicity** | ✅ Perfect | ⚠️ Requires Manifest |

### Example: Electron Apps in node_modules

```
node_modules/
├── electron/           # 300MB
├── puppeteer/         # 200MB (contains Chromium)
└── electron-prebuilt/ # 300MB (mostly duplicate)
```

With granular ingestion: **~350MB stored** (instead of 800MB)

---

## Implementation Strategy: Bundle Meta + Clone Mode

### 1. Bundle Manifest

When ingesting a `.app` directory, generate a manifest:

```json
{
  "type": "signed_bundle",
  "path": "Chromium.app",
  "files": [
    {"rel": "Contents/Info.plist", "hash": "abc123...", "mode": 0644},
    {"rel": "Contents/MacOS/Chromium", "hash": "def456...", "mode": 0755}
  ],
  "symlinks": [
    {"rel": "Contents/Frameworks/Current", "target": "../Versions/A"}
  ]
}
```

### 2. Signed Bundle Detection

```rust
fn is_signed_bundle(path: &Path) -> bool {
    path.extension()
        .map(|ext| ext == "app" || ext == "framework")
        .unwrap_or(false)
}
```

### 3. Clone Mode Enforcement

When restoring files from a signed bundle:

```rust
if is_signed_bundle(parent_dir) {
    // Force clonefile → separate inode → satisfies Gatekeeper
    reflink_copy::reflink(cas_blob, target)?;
} else {
    // Normal hard_link
    fs::hard_link(cas_blob, target)?;
}
```

---

## Critical Edge Cases

### Symlinks Inside .app

`.app` bundles contain relative symlinks (especially in `Frameworks/`):

```
Contents/Frameworks/
├── Foo.framework/Versions/A/Foo      # Real binary
└── Foo.framework/Foo -> Versions/A/Foo  # Symlink
```

**Requirement**: CAS must store symlink metadata and recreate them exactly.

### Code Signature Verification

macOS verifies bundle integrity on first launch. If:
- Hard links used → EPERM / "damaged app" dialog
- Missing symlinks → Crash on launch
- Wrong permissions → Gatekeeper rejection

**Solution**: Use `clonefile` + preserve exact permissions + recreate symlinks

---

## Related Patterns

| Pattern | Issue | Solution |
|---------|-------|----------|
| 987 | EPERM on hard_link | Tiered fallback (this RFC) |
| TBD | Symlink preservation | Store link target in manifest |
| TBD | Permission preservation | Store mode bits in manifest |
| TBD | Bundle validation | Verify after restore |

---

# Appendix B: Cross-Ecosystem Hard Link Hazards

> **Key Insight**: macOS EPERM is a signal that `hard_link` is becoming obsolete for modern development workflows.

## Affected Ecosystems

### Python (uv / pip)

| Issue | Scenario |
|-------|----------|
| **Framework Bundles** | PySide/PyQt, matplotlib backends contain `.framework` |
| **RPATH Pollution** | `dyld` rejects signed `.dylib` from unknown CAS path |
| **Gatekeeper** | "Malicious software" warning when inode points to CAS |

### Rust (cargo)

| Issue | Scenario |
|-------|----------|
| **build.rs Artifacts** | openssl-sys, ring download precompiled binaries |
| **cargo-bundle** | Generated `.app` triggers same EPERM |
| **Target Directory** | Hard-linked build artifacts break codesign |

### C/C++ (Clang/CMake)

| Issue | Scenario |
|-------|----------|
| **Framework Structure** | `.framework` requires physical integrity |
| **Signature Pollution** | Signing one path corrupts CAS source for others |
| **Incremental Build** | Shared mtime triggers phantom rebuilds |

---

## Core Problem Matrix

| Problem | Symptom | Affected | Root Cause |
|---------|---------|----------|------------|
| **Signature Readonly** | EPERM | All signed binaries | Kernel blocks inode modification |
| **RPATH Pollution** | Library not found | Python, C++ | `install_name_tool` modifies CAS source |
| **Sandbox Isolation** | Operation not permitted | App Store builds | Sandbox rejects external inodes |
| **Mtime Sync** | Phantom rebuilds | Cargo, Ninja | Hard links share modification time |

---

## Binary-Sensitive Extensions

Mark these as `NO_HARDLINK` in velovfs:

```
.app .framework .dylib .so .a .bundle .plugin .kext
```

---

## Recommended Strategy for velovfs

### 1. Detect Binary-Sensitive Zones

```rust
fn is_binary_sensitive(path: &Path) -> bool {
    let sensitive = ["app", "framework", "dylib", "so", "a", "bundle"];
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| sensitive.contains(&e))
        .unwrap_or(false)
}
```

### 2. Prefer clonefile as First-Class Citizen

On macOS, use `clonefile` by default for all binary artifacts:

```rust
if cfg!(target_os = "macos") && is_binary_sensitive(path) {
    reflink_copy::reflink(source, target)?;
} else {
    link_or_clone_or_copy(source, target)?;
}
```

### 3. Mtime Isolation

Hard links share mtime → one project's build invalidates another's cache.

**Solution**: Clone provides independent mtime, eliminating "phantom rebuilds".

---

## Summary

| Strategy | When to Use |
|----------|-------------|
| `hard_link` | Text files, source code, non-sensitive assets |
| `clonefile` | Signed binaries, .dylib, .framework, build artifacts |
| `copy` | Cross-filesystem, non-APFS volumes |

> **Conclusion**: For py/cargo/c++ acceleration, VFS must be smarter than pnpm — treat `clonefile` as the primary operation on macOS.

---

# Appendix C: FUSE Interception vs Sync Layer

## Architecture Decision

Two approaches to handle special file types:

| Approach | Description | Timing |
|----------|-------------|--------|
| **Sync Layer** | Handle in Ingest/Populate phase | Build-time |
| **FUSE Layer** | Intercept syscalls at runtime | Runtime |

> **Key Trade-off**: Sync layer is "symptomatic treatment", FUSE is "root cause fix"

---

## Option 1: Sync Layer (Ingest/Populate)

velovfs acts as an "offline" link manager (like pnpm).

### Implementation

```rust
// During Ingest
if is_signed_bundle(path) {
    mark_as(NEEDS_CLONE);
}

// During Populate
if needs_clone(file) {
    clonefile(cas_blob, target);
} else {
    hard_link(cas_blob, target);
}
```

### Pros

| Benefit | Description |
|---------|-------------|
| **Performance** | Native kernel speed, zero FUSE overhead |
| **Simplicity** | Just add if-branches in Rust |
| **Predictable** | All decisions at install time |

### Cons

| Limitation | Description |
|------------|-------------|
| **Passive** | Can't detect runtime-generated signed binaries |
| **Static** | Pre-baked directory structure |

---

## Option 2: FUSE Interception

velovfs is a live mounted filesystem process.

### Implementation

```rust
// In FUSE link() handler
fn fuse_link(&self, source: &Path, target: &Path) -> Result<()> {
    if would_trigger_eperm(target) {
        // Transparent downgrade to clonefile
        reflink_copy::reflink(source, target)?;
    } else {
        fs::hard_link(source, target)?;
    }
    Ok(())
}
```

### Pros

| Benefit | Description |
|---------|-------------|
| **Transparent** | npm/cargo/clang unaware of workaround |
| **Dynamic** | Real-time IO pattern observation |
| **Flexible** | Can COW on write detection |

### Cons

| Limitation | Description |
|------------|-------------|
| **Performance** | Kernel↔Userspace context switch overhead |
| **Deadlock Risk** | inode lock management complexity |
| **Small Files** | FUSE overhead significant for node_modules |

---

## Recommended: Hybrid Strategy

> **"Sync Layer for 95%, FUSE for dynamic COW"**

### Strategy A: Sync Layer for Static Assets (Default)

During `velo install`:

| File Type | Action |
|-----------|--------|
| Regular files | `hard_link` |
| Signed bundles | `clonefile` |
| Symlinks | Recreate exactly |

### Strategy B: FUSE Write-Time Clone for Build Artifacts

Intercept `open()` / `write()` calls:

```rust
fn fuse_write(&self, path: &Path, data: &[u8]) -> Result<()> {
    if is_cas_managed(path) {
        // Create private copy on first write
        let private = self.clone_to_private(path)?;
        write_to(private, data)
    } else {
        write_to(path, data)
    }
}
```

This solves:
- Signature issues
- Cross-project pollution
- Incremental build correctness

---

## Warning: macOS App Sandbox

> ⚠️ **sandboxd interaction**

Sandboxed apps (App Store tools, some IDE plugins) may crash if:
- inode changes unexpectedly (link → clone swap)
- File appears to violate security policy

**Mitigation**: Document which tools are sandbox-safe.

---

## Decision Matrix

| Scenario | Recommended Approach |
|----------|----------------------|
| npm install | Sync Layer (Populate) |
| cargo build | Sync Layer + FUSE COW |
| C++ incremental | FUSE COW on write |
| Signed .app access | Sync Layer (clonefile) |

---

# Appendix D: Async IO Optimization (io_uring / kqueue)

## Goal

Handle "silent downgrade" (link → clonefile) without adding latency.

> **Key Insight**: Eliminate blocking + use heuristics for prediction

---

## Strategy 1: Path Pattern Fast-Path

Maintain a Bloom Filter for known sensitive paths:

```rust
fn should_skip_hardlink(path: &Path) -> bool {
    // O(1) lookup in memory
    SENSITIVE_PATHS.probably_contains(path)
        || path.to_string_lossy().contains(".app/")
        || path.to_string_lossy().contains(".framework/")
}
```

**Effect**: Skip doomed `link()` attempt → save kernel roundtrip

---

## Strategy 2: Optimistic Concurrent Execution

```rust
async fn link_with_fallback(src: &Path, dest: &Path) -> Result<()> {
    // Dispatch to worker pool immediately
    tokio::spawn_blocking(move || {
        match fs::hard_link(&src, &dest) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == io::ErrorKind::PermissionDenied => {
                // EPERM: instant retry with clonefile
                reflink_copy::reflink(&src, &dest)
            }
            Err(e) => Err(e),
        }
    }).await?
}
```

**Key Point**: clonefile on APFS is metadata-only → nearly same speed as link

---

## Linux: io_uring — Revolutionary Performance

### Why io_uring?

| Feature | Traditional IO | io_uring |
|---------|----------------|----------|
| Context Switch | Every syscall | Zero (shared ring buffer) |
| Batching | N syscalls | 1 submission |
| Chaining | Manual | Kernel-native |

### Application to FUSE Backend

```rust
// Submit batch of writes to CAS in one ring submission
let mut ring = IoUring::new(256)?;

for file in files_to_ingest {
    ring.submission().push(
        Write::new(file.fd, file.data)
            .build()
    )?;
}

// Single kernel entry for all writes
ring.submit_and_wait(files.len())?;
```

### Linked Operations

```rust
// Atomic: write → fsync → hardlink (all in kernel)
ring.submission()
    .push(Write::new(fd, data).build())?
    .push(Fsync::new(fd).build().flags(IOSQE_IO_LINK))?
    .push(Link::new(src, dest).build().flags(IOSQE_IO_LINK))?;
```

---

## macOS: kqueue — Event-Driven, Not Async

### Fundamental Difference

| Aspect | kqueue | io_uring |
|--------|--------|----------|
| Model | "IO ready" notification | "Execute IO for me" |
| Role in FUSE | Listen for /dev/fuse events | Execute backend operations |
| True Async | ❌ | ✅ |

### macOS Optimization Strategy

Since macOS lacks io_uring equivalent:

```rust
// Use tokio blocking pool to simulate async
async fn macos_batch_ingest(files: Vec<PathBuf>) -> Result<()> {
    let handles: Vec<_> = files.into_iter().map(|f| {
        tokio::task::spawn_blocking(move || {
            link_or_clone_or_copy(&f.src, &f.dest)
        })
    }).collect();
    
    futures::future::try_join_all(handles).await?;
    Ok(())
}
```

**macOS-specific APIs**:
- `fcopyfile()` for fast cloning
- `posix_spawn()` for subprocess parallelism

---

## Performance Comparison

| Mode | Latency Source | Throughput |
|------|----------------|------------|
| **Sync FUSE** | Disk IO + context switch | Low |
| **kqueue + Thread Pool** | Thread switch overhead | Medium (macOS best) |
| **io_uring** | Physical IO only | High (Linux best) |

---

## Architecture: VfsBackend Trait

Abstract platform differences:

```rust
#[async_trait]
trait VfsBackend: Send + Sync {
    /// Platform-optimal link or clone
    async fn link_or_clone(&self, src: PathBuf, dest: PathBuf) -> Result<()>;
    
    /// Batch ingest with io_uring (Linux) or thread pool (macOS)
    async fn batch_ingest(&self, files: Vec<FilePayload>) -> Result<()>;
    
    /// Ensure durability before returning to FUSE
    async fn sync(&self) -> Result<()>;
}

// Implementations
struct LinuxBackend { ring: IoUring }
struct MacosBackend { pool: ThreadPool }
```

---

## Edge Cases

| Issue | Platform | Mitigation |
|-------|----------|------------|
| io_uring hardlink instability | Old Linux kernels | Check kernel version |
| LMDB async data loss | Both | Chain fsync in io_uring |
| OverlayFS symlink limits | Linux | Detect FS type |

---

## Summary

| Platform | Async Engine | Silent Downgrade Strategy |
|----------|--------------|---------------------------|
| **Linux** | io_uring | Batched link+clone in kernel |
| **macOS** | kqueue + tokio | Thread pool + path prediction |
