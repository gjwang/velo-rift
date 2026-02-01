# RFC-0048: Compiler Syscall Gap Analysis

## Status: Draft

---

## Abstract

This RFC documents syscalls that are critical to compiler/build systems but not yet virtualized in the VFS shim. These gaps can cause build failures or incorrect incremental builds.

---

## Risk Assessment

| Syscall | Risk | Impact | Use Case |
|---------|------|--------|----------|
| `ftruncate` | 🔴 HIGH | Corrupted output | GCC assembler truncates .o files |
| `utimes` | 🔴 HIGH | Stale incremental builds | Make/Ninja mtime touch |
| `lseek` | 🔴 HIGH | Archive corruption | ar/tar random access |
| `pread/pwrite` | 🟡 MEDIUM | Linker failures | Parallel section reading |
| `symlink` | 🟡 MEDIUM | Library failures | libfoo.so → libfoo.so.1 |
| `flock` | 🟡 MEDIUM | Parallel build races | ccache, distcc |
| `fchmod/fchown` | 🟡 MEDIUM | Permission errors | Install steps |
| `dup2` | 🟢 LOW | Minor | Usually shell FDs |
| `fsync` | 🟢 LOW | None | Passthrough OK |

---

## Detailed Analysis

### 1. ftruncate (HIGH RISK)

**Use Case:**
```c
// Compiler output pattern
fd = open("output.o", O_WRONLY | O_TRUNC);  // or
fd = open("output.o", O_WRONLY);
ftruncate(fd, 0);  // Clear before writing
write(fd, data, size);
close(fd);
```

**Current Behavior:** Passthrough
**Problem:** If FD is tracked VFS file, truncate goes to wrong file
**Fix:** Track FD, apply truncate to CoW temp file

---

### 2. utimes/futimes (HIGH RISK)

**Use Case:**
```bash
# Make touch for dependency tracking
touch -t 202601011200 header.h
make  # Should rebuild dependents

# Ninja restat
ninja -t touch target
```

**Current Behavior:** Passthrough
**Problem:** VFS mtime never updated → Make sees stale timestamps
**Fix:** Update Manifest mtime field

---

### 3. lseek (HIGH RISK)

**Use Case:**
```c
// Archive tool pattern
fd = open("libfoo.a", O_RDONLY);
lseek(fd, offset, SEEK_SET);
read(fd, header, sizeof(header));
```

**Current Behavior:** Passthrough
**Problem:** If FD extracted from CAS to temp, lseek/read mismatch
**Fix:** Ensure extracted temp FD remains consistent

---

### 4. symlink (MEDIUM RISK)

**Use Case:**
```bash
# Library versioning
ln -s libfoo.so.1.0.0 libfoo.so.1
ln -s libfoo.so.1 libfoo.so

# npm bin links
ln -s ../package/bin/cli.js node_modules/.bin/cli
```

**Current Behavior:** Passthrough
**Problem:** Real symlink created, not in VFS Manifest
**Fix:** Add Manifest symlink entry with target

---

## Priority Implementation Order

1. **P0: ftruncate** - Compiler output reliability
2. **P0: utimes** - Incremental build correctness
3. **P1: lseek** - Archive tool support
4. **P1: symlink** - Library versioning
5. **P2: flock** - Parallel build safety
6. **P2: pread/pwrite** - Linker optimization

---

## Test Coverage

| Gap | Test File | Status |
|-----|-----------|--------|
| ftruncate | `test_gap_ftruncate.sh` | ❌ FAIL |
| utimes | `test_gap_utimes.sh` | ❌ FAIL |
| lseek | `test_gap_lseek.sh` | ❌ FAIL |
| symlink | `test_gap_symlink.sh` | ❌ FAIL |

---

## Related RFCs

- RFC-0047: Syscall Audit (mutation semantics)
- RFC-0039: VFS Architecture
