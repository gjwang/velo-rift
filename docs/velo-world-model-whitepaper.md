# Velo Rift — One‑Page Whitepaper

## The Problem

Modern runtimes are fast. Disks are not.

```text
Python startup:  95% time = loading files from disk
Node.js startup: 90% time = resolving node_modules
Rust build:      80% time = waiting for I/O
```

The filesystem is the bottleneck.

---

## The Solution

**Remove the filesystem from the critical path.**

```text
Before:  open() → disk seek → read → copy to memory → use
After:   open() → mmap pointer → use
```

---

## How It Works

| Step | What Happens |
|------|-------------|
| 1. Content-address everything | Files identified by content hash, not path |
| 2. Deduplicate globally | Same bytes = stored once, regardless of location |
| 3. mmap on access | Zero-copy, no extraction, no disk I/O |

---

## What Velo Rift Does

> **Make file access instant.**

That's it.

---

## What Velo Rift Does NOT Do

| Not Our Job | Whose Job |
|-------------|-----------|
| Build graphs | Bazel |
| Package resolution | uv, npm, cargo |
| Process isolation | Docker |
| Distributed consensus | etcd |

We integrate with these tools. We don't replace them.

---

## Result

| Metric | Before | After |
|--------|--------|-------|
| `npm install` | 2 min | < 1 sec |
| Python cold start | 500ms | 50ms |
| Disk usage (10 projects) | 10 GB | 1 GB |

---

## One Sentence

> **Velo Rift makes file access instant by eliminating disk I/O.**

---

*Version 3.0 — 2026-01-29*
