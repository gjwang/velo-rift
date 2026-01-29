# Velo Rift VFS — Whitepaper

## Two Problems, One Solution

Velo Rift VFS solves exactly **two problems**:

### 1. Read-Only File Access is Too Slow

```text
Traditional:  open() → disk seek → read → copy → use
Velo Rift:    open() → mmap pointer → use
```

**Result**: Microseconds instead of milliseconds.

### 2. Duplicate Files Waste Storage

```text
Traditional:  10 projects × same dependency = 10 copies
Velo Rift:    10 projects × same dependency = 1 copy (shared)
```

**Result**: 10x storage reduction.

---

## How It Works

| Mechanism | Purpose |
|-----------|---------|
| Content-Addressable Storage | Same bytes = same hash = stored once |
| Memory-Mapped I/O | Zero-copy access, no disk reads |

---

## What We Don't Do

| Not Our Job | Use Instead |
|-------------|-------------|
| Build orchestration | Bazel |
| Package resolution | uv, npm, cargo |
| Process isolation | Docker |
| Mutable file storage | Filesystem |

---

## Summary

> **Fast read-only access. Zero duplication.**

That's Velo Rift.

---

*v4.0 — 2026-01-29*
