# RFC-0047 Syscall Compliance Audit

## Purpose

Velo Rift's goal is **compiler/build acceleration** through content-addressable deduplication.

**Key Insight:** Not every syscall needs virtualization. The decision depends on:
1. Does it affect **dependency tracking** (mtime)?
2. Does it affect **content integrity** (read/write)?
3. Does it affect **namespace consistency** (path resolution)?

---

## Scenario-Based Analysis

### 🎯 Our Goal: Compiler Acceleration

Typical compiler workflow:
```
1. Read source files      → stat, open, read, mmap
2. Check dependencies     → stat mtime comparison
3. Compile                 → internal
4. Write output            → open(O_WRONLY), write, close
5. Atomic replace          → rename(tmp, final)
6. Update archives         → ar: lseek, write
7. Link                    → dlopen, mmap
```

**Question for each syscall: Does it need virtualization?**

---

## Syscall Classification

### ✅ Must Virtualize (Affects VFS Semantics)

| Syscall | Why Must Virtualize | Impact if Passthrough |
|---------|---------------------|----------------------|
| `stat/lstat/fstat` | Mtime for dependency tracking | Wrong rebuild decisions |
| `open(O_RDONLY)` | Read from CAS | Wrong file content |
| `realpath/getcwd/chdir` | Path namespace | Path mismatch |
| `opendir/readdir` | Directory listing | Missing files |
| `unlink` | Remove from Manifest | Real file deleted accidentally |
| `rename` | Update Manifest path | Atomic replace fails |
| `utimes` | Update Manifest mtime | Stale incremental builds |

### ⚡ Can Passthrough (No VFS Impact)

| Syscall | Why Passthrough OK | Rationale |
|---------|-------------------|-----------|
| `read/write` | FD already points to correct file | Pre-extracted or CoW temp |
| `lseek` | FD position is FD-local | Works on extracted temp |
| `pread/pwrite` | Same as lseek | FD-local operation |
| `ftruncate` | If CoW temp exists, truncate it | FD-local operation |
| `fsync/fdatasync` | CAS is already durable | No-op is safe |
| `mmap/munmap` | FD-based, works on temp | FD already correct |
| `fcntl` | FD flags, no VFS impact | FD-local |
| `dup/dup2` | FD duplication | FD-local |
| `flock` | FD-based locking | Works on temp file |

### ⚠️ Needs Manifest Update (Current Gaps)

| Syscall | Current | Required | Priority |
|---------|---------|----------|----------|
| `open(O_WRONLY)` | break_link + passthrough | CoW temp + track FD | P0 |
| `close` | passthrough | If dirty: hash → CAS → Manifest | P0 |
| `unlink` | EROFS | Remove Manifest entry | P0 |
| `rename` | EROFS | Update Manifest path | P0 |
| `rmdir` | EROFS | Remove Manifest dir | P0 |
| `utimes` | passthrough | Update Manifest mtime | P0 |
| `mkdir` | passthrough | Add Manifest dir entry | P1 |
| `symlink` | passthrough | Add Manifest symlink | P1 |
| `fchmod/chmod` | passthrough | Update Manifest mode | P2 |

---

## Deep Analysis: Why EROFS Breaks Compilers

### The GCC/Clang Workflow

```bash
gcc -c foo.c -o foo.o
```

Internally:
```
1. cc1: compile → write to /tmp/ccXXX.s
2. as: assemble → create foo.o (may truncate existing)
3. If foo.o exists: unlink(foo.o) or open(O_TRUNC)
4. rename(/tmp/ccXXX.o, foo.o) - atomic replace
```

**Current Problem:**
- Step 3: `unlink(foo.o)` returns EROFS → **Compilation fails**
- Step 4: `rename()` returns EROFS → **Atomic replace fails**

**Required Behavior:**
- `unlink(foo.o)` → Remove from Manifest (CAS blob unchanged)
- `rename(tmp, foo.o)` → Update Manifest path, compute new hash

---

## Deep Analysis: Why utimes Matters

### The Make Workflow

```makefile
foo.o: foo.c foo.h
    $(CC) -c foo.c -o foo.o
```

```bash
touch foo.h  # Mark as modified
make         # Should rebuild foo.o
```

How Make works:
```
1. stat(foo.o) → mtime_o
2. stat(foo.h) → mtime_h
3. if mtime_h > mtime_o: rebuild
```

**Current Problem:**
- `touch foo.h` → Passthrough to real FS
- VFS Manifest still has old mtime
- Make sees stale mtime → **Skips rebuild**

**Required Behavior:**
- `utimes(foo.h, ...)` → Update Manifest mtime

---

## Analysis: What Doesn't Need Virtualization

### lseek/pread/pwrite

**Question:** If we extract CAS blob to temp, does lseek break?
**Answer:** No! The FD points to the extracted temp file, lseek works correctly.

```c
// VFS: /vrift/project/libfoo.a
fd = open("/vrift/project/libfoo.a", O_RDONLY);
// → Shim extracts CAS blob to /tmp/vrift_xxxx
// → Returns FD to /tmp/vrift_xxxx

lseek(fd, 100, SEEK_SET);  // Seeks in /tmp/vrift_xxxx ✅
read(fd, buf, 50);         // Reads from /tmp/vrift_xxxx ✅
```

**Conclusion:** Passthrough is correct. FD abstraction handles it.

### ftruncate

**Question:** If compiler truncates output file, does VFS break?
**Answer:** Depends on write path implementation.

If we implement CoW correctly:
```c
// open(O_WRONLY) → creates temp, tracks FD
// ftruncate(fd) → truncates temp ✅
// write(fd) → writes to temp ✅
// close(fd) → hash temp → CAS → Manifest ✅
```

**Conclusion:** Passthrough is correct IF CoW is implemented.

---

## Current Status Summary

| Category | Count | Status |
|----------|-------|--------|
| Read Path (stat, open, read) | 13 | ✅ Correct |
| Namespace (realpath, getcwd, chdir) | 3 | ✅ Correct |
| Execution (execve, posix_spawn, dlopen) | 5 | ✅ Correct |
| Memory (mmap, munmap) | 2 | ✅ Passthrough OK |
| FD Operations (lseek, pread, ftruncate) | 5 | ✅ Passthrough OK |
| Write Path (open, write, close) | 3 | ⚠️ CoW incomplete |
| Mutation (unlink, rename, rmdir) | 3 | ❌ EROFS wrong |
| Mtime (utimes) | 1 | ❌ Not virtualized |
| Directory (mkdir, symlink) | 2 | ⚠️ Passthrough only |

---

## Priority Implementation

### P0: Compiler Blocking (Must Fix)

1. **unlink/rename/rmdir** → Replace EROFS with Manifest ops
2. **utimes** → Update Manifest mtime
3. **CoW close** → Hash → CAS → Manifest on dirty FD

### P1: Archive/Linker Support

4. **mkdir** → Create Manifest dir entry
5. **symlink** → Create Manifest symlink entry

### P2: Nice-to-Have

6. **fchmod/chmod** → Update Manifest mode

---

## Test Coverage

| Gap | Test | Result |
|-----|------|--------|
| Mode check | `test_rfc0047_open_mode_check.sh` | ❌ FAIL |
| unlink | `test_rfc0047_unlink_vfs.sh` | ❌ FAIL |
| rename | `test_rfc0047_rename_vfs.sh` | ❌ FAIL |
| rmdir | `test_rfc0047_rmdir_vfs.sh` | ❌ FAIL |
| CoW close | `test_rfc0047_cow_write_close.sh` | ❌ FAIL |
| mkdir | `test_rfc0047_mkdir_vfs.sh` | ❌ FAIL |
| utimes | `test_gap_utimes.sh` | ❌ FAIL |
| symlink | `test_gap_symlink.sh` | ❌ FAIL |

---

## Verification Status

| Component | Status | Evidence |
|-----------|--------|----------|
| VnodeEntry has mode | ✅ | `vrift-manifest/lib.rs` |
| stat() returns mode | ✅ | `vrift-shim/lib.rs` |
| open() checks mode | ❌ | No check in open_impl |
| Manifest.remove() | ✅ | Exists but shim doesn't call |
| unlink/rename/rmdir | ❌ | Return EROFS |
| utimes | ❌ | Not intercepted |
| CoW write path | ❌ | close() doesn't reingest |
