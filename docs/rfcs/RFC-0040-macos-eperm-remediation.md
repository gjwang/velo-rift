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
