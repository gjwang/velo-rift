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
