# Velo Rift

> **Modern runtimes are fast. Disks are not.**  
> Velo Rift removes the filesystem from the critical path of computation.

---

## Two Problems, One Solution

### 1. Read-Only File Access is Too Slow

```text
Traditional:  open() → disk seek → read → copy → use
Velo Rift:    open() → mmap pointer → use
```

### 2. Duplicate Files Waste Storage

```text
Traditional:  10 projects × same dependency = 10 copies
Velo Rift:    10 projects × same dependency = 1 copy (shared)
```

---

## How It Works

| Mechanism | Purpose |
|-----------|---------|
| **Content-Addressable Storage** | Same bytes = same hash = stored once |
| **Memory-Mapped I/O** | Zero-copy access, no disk reads |

---

## What Velo Rift IS

- ✅ A **virtual file system** for read-only content
- ✅ A **content-addressable store** with global deduplication

## What Velo Rift is NOT

- ❌ A runtime replacement (we accelerate existing runtimes)
- ❌ A package manager (we wrap uv, npm, cargo)
- ❌ A build system (that's Bazel's job)
- ❌ A container runtime (that's Docker's job)

---

## Results

| Metric | Before | After |
|--------|--------|-------|
| `npm install` | 2 min | < 1 sec |
| Python cold start | 500ms | 50ms |
| Disk usage (10 projects) | 10 GB | 1 GB |

---

## Documentation

| Document | Description |
|----------|-------------|
| [Whitepaper](docs/velo-world-model-whitepaper.md) | Two core problems explained |
| [Positioning](docs/architecture/velo-technical-positioning.md) | Comparison with other tools |
| [Technical Spec](docs/architecture/velo-technical-deep-dive.md) | Implementation details |

---

## Who Should Use Velo Rift

**Yes:**
- Large dependency trees (1000+ packages)
- Cold start latency matters (serverless, CI/CD)

**No:**
- Write-heavy mutable workloads
- Bottleneck is CPU, not I/O
- < 100 dependencies

---

## Status

🚧 **Early Development** — Architecture defined, implementation in progress.

## License

Apache 2.0
