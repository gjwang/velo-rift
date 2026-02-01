# RFC-0047: VFS Mutation Semantics

## Status: Draft

---

## Abstract

Velo Rift provides a transparent virtual filesystem for compilation acceleration. This RFC defines the mutation semantics: how syscalls behave within the VFS while faithfully reflecting original file permissions.

---

## Core Principles

1. **CAS is immutable** - Content-addressable blobs are never modified or deleted by syscalls
2. **Manifest is the view** - User sees paths defined by Manifest entries
3. **Transparent to tools** - VFS is invisible; all operations work normally
4. **Faithful permission reflection** - VFS reflects original file permissions exactly

---

## Permission Model

### Key Insight

VFS does not impose read-only policies. Instead, it **faithfully reflects the original permissions** from when files were ingested.

```
Original file: .venv/numpy.so (mode: 0o444, read-only)
    ↓ ingest
Manifest entry: { path: ".venv/numpy.so", hash: abc123, mode: 0o444 }
    ↓ VFS view
stat() → mode: 0o444
open(O_WRONLY) → EACCES (because mode forbids write)
```

### Two Cases

| Case | Manifest Entry? | Behavior |
|------|-----------------|----------|
| **Existing file** | ✅ Yes | Check `mode` from Manifest |
| **New file** | ❌ No | Create with requested mode |

### Examples

```python
# Case 1: Read existing file (Manifest has entry)
open(".venv/numpy.so", O_RDONLY)  # → Success, read from CAS

# Case 2: Write to read-only file (Manifest mode = 0o444)
open(".venv/numpy.so", O_WRONLY)  # → EACCES (permission denied)

# Case 3: Write to writable file (Manifest mode = 0o644)
open("src/main.py", O_WRONLY)     # → Success, CoW + update Manifest

# Case 4: Create new file (no Manifest entry)
open("target/main.o", O_CREAT|O_WRONLY, 0o644)  # → Create new entry
```

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│  User/Compiler sees:  /vrift/project/...        │
│  (Transparent Virtual View)                     │
└─────────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────┐
│  Manifest (per-project, mutable)                │
│  .venv/numpy.so → hash:abc, mode:0o444          │
│  src/main.py    → hash:def, mode:0o644          │
│  (target/ may not exist until created)          │
└─────────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────┐
│  CAS (TheSource, global, immutable)             │
│  abc123 → [content bytes]                       │
│  def456 → [content bytes]                       │
└─────────────────────────────────────────────────┘
```

---

## Syscall Behavior

| Syscall | Entry Exists? | Mode Check | Action |
|---------|---------------|------------|--------|
| `open(O_RDONLY)` | ✅ | R bit | Return CAS content |
| `open(O_WRONLY)` | ✅ | W bit | CoW + track FD |
| `open(O_WRONLY)` | ❌ | - | Create new entry |
| `stat` | ✅ | - | Return Manifest mode |
| `unlink` | ✅ | W bit on parent | Remove Manifest entry |
| `rename` | ✅ | W bit | Update Manifest path |
| `mkdir` | ❌ | - | Add Manifest dir entry |
| `chmod` | ✅ | Owner | Update Manifest mode |

---

## Write Path (CoW)

```
1. open("/vrift/project/file.txt", O_WRONLY)
   → Check Manifest: mode allows write?
   → Create temp file, track FD

2. write(fd, data)
   → Write to temp file

3. close(fd)
   → Hash temp → insert CAS → update Manifest hash
   → Preserve original mode
```

---

## Implementation Requirements

1. **Manifest stores mode** - Each entry has `mode: u32`
2. **open() checks mode** - Respect permission bits
3. **stat() returns mode** - From Manifest entry
4. **New files use requested mode** - Pass through from syscall

---

## Current vs Target State

| Syscall | Current | Target |
|---------|---------|--------|
| `open(write)` | ⚠️ No mode check | ✅ Check Manifest mode |
| `stat` | ✅ Returns mode | ✅ OK |
| `unlink` | ❌ EROFS | ✅ Remove entry (check perms) |
| `rename` | ❌ EROFS | ✅ Update path (check perms) |
| `mkdir` | ⏳ Passthrough | ✅ Add Manifest entry |
