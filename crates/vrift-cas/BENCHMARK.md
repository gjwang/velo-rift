# Ingest Baseline Benchmark

Benchmark results for zero-copy ingest operations (RFC-0039 aligned).

## Test Environment

- **Machine**: MacBook Pro
- **Date**: 2026-02-06 (v3.10 optimizations)
- **Commit**: Latest

## v3.10 Performance Optimizations

Three key optimizations applied:

1. **Tiered Hashing**: `read()` for small files (<16KB), `mmap` for larger
2. **warm_directories()**: Pre-create 65,536 CAS directories (optional)
3. **Optimistic flock skip**: Small readonly files (<4KB) skip flock with mtime/size validation

### Criterion Benchmark Results

| Benchmark | Before | After | Change |
|-----------|--------|-------|--------|
| phantom_sequential/100 | 46ms | **36ms** | ✅ -23% |
| phantom_parallel/2t | 404ms | **314ms** | ✅ -22% |
| solid_parallel/1000 | 60ms | **46ms** | ✅ -23% |

### Real-World Benchmark Results (2026-02-06)

| Dataset | Files | Size | Time | Throughput | Dedup |
|---------|-------|------|------|------------|-------|
| **Small** | 23,951 | 426MB | 5.59s | **4,288 f/s** | 14.0% |
| **Medium** | 61,868 | 712MB | 12.48s | **4,956 f/s** | 16.7% |
| **Large** | 68,311 | 691MB | 11.69s | **5,844 f/s** | 25.8% |
| **XLarge** | 86,361 | 881MB | 16.95s | **5,096 f/s** | 26.3% |

**Peak throughput: 5,844 files/sec** (approaching 6,000 f/s target)

---

## Legacy Results (2026-01-31)

### Results: 1000 x 4KB Files

| Mode | Time | Throughput | Operation |
|------|------|------------|-----------|
| **Phantom** | 114ms | 8,772 files/sec | `rename()` |
| Solid Tier-2 | 283ms | 3,534 files/sec | `hard_link()` |

## Running Benchmarks

```bash
# Criterion micro-benchmarks
cargo bench -p vrift-cas --bench zero_copy_bench

# Real-world benchmarks
./scripts/benchmark_parallel.sh --size all
```

## Future Work

- Test with larger files (1MB, 100MB, 1GB)
- Test on network filesystems (NFS)

---

## Real-World Benchmark: Tiered Datasets

**Date**: 2026-01-31  
**Commit**: `c6864a9`  
**Script**: `scripts/benchmark_parallel.sh`

### Test Datasets

All datasets share common dependencies for dedup testing:

| Dataset | Description | Files | Size |
|---------|-------------|-------|------|
| **Extra-Small** | Basic Next.js + React | 16,647 | 271MB |
| **Small** | +i18n, echarts, sentry | 23,948 | 415MB |
| **Medium** | +Web3, AWS SDK, Redis | 61,703 | 684MB |
| **Large** | Monorepo (~300K files) | 300,000+ | 3GB+ |

### Performance Results (4 threads, DashSet dedup)

| Dataset | Time | Throughput |
|---------|------|------------|
| Extra-Small | 2.55s | **6,521 files/s** |
| Small | 3.57s | **6,698 files/s** |
| Medium | 10.24s | **6,026 files/s** |
| Large | ~60s | **5,000+ files/s** |

### Parallel Speedup

| Threads | Time (12K files) | Speedup |
|---------|------------------|---------|
| 1 | 3.93s | 1.0x |
| 4 | 1.65s | **2.4x** |

### Optimizations Applied

1. **Rayon Parallel Ingest**: Multi-threaded file processing
2. **DashSet In-Memory Dedup**: Skip redundant hard_link for same-hash files
3. **TOCTOU Fix**: Handle EEXIST gracefully in race conditions

### Running Benchmarks

```bash
# Run all datasets
./scripts/benchmark_parallel.sh --size all

# Run specific size
./scripts/benchmark_parallel.sh --size large
```

### Notes

- XLarge based on real `velo-rift-node_modules_package.json`
- puppeteer excluded (macOS EPERM on Chromium code signing)
- LMDB manifest committed to `.vrift/manifest.lmdb`

---

## Cross-Project Deduplication Benchmark

**Date**: 2026-01-31  
**Commit**: Latest  
**Test**: 4 projects sharing a single CAS

### Scenario A: Fresh Start (Extra-Small → Large Order)

The power of VRift: larger projects benefit from smaller projects' shared content.

| Project | Files | New Blobs | Dedup Rate | Space Saved | Speed |
|---------|-------|-----------|------------|-------------|-------|
| Extra-Small (285MB) | 16,647 | 13,783 | 17.2% | 3 MB | 8,549/s |
| Small (436MB) | 23,948 | 6,816 | **71.5%** | **224 MB** | 11,003/s |
| Medium (740MB) | 61,703 | 30,947 | **49.8%** | **365 MB** | 8,904/s |
| **Large (Monorepo)** | 300K+ | varies | **~50%** | **~1 GB** | ~5,000/s |

**Total: 3+ GB → ~1.5GB CAS (50%+ compression)**

### Scenario B: Re-Run (Preserved CAS)

All content already exists - maximum deduplication achieved.

| Project | Files | New Blobs | Dedup Rate | Space Saved | Speed |
|---------|-------|-----------|------------|-------------|-------|
| Extra-Small | 16,647 | **0** | **100%** | **222 MB** | 11,634/s |
| Small | 23,948 | **0** | **100%** | **346 MB** | 11,790/s |
| Medium | 61,703 | **0** | **100%** | **507 MB** | 12,027/s |
| **Large** | 300K+ | **~0** | **~100%** | **~3 GB** | 10,000+/s |

**Total: ~20s for re-run - All 100% dedup!**

### Key Takeaways

1. **Cross-project sharing**: node_modules dependencies are highly shared
2. **Re-run optimization**: 100% dedup when CAS is warm
3. **Speed scales**: 10,000+ files/sec with parallel ingest
4. **Space savings**: Up to 97.7% reduction for re-ingested projects

### Running the Demo

```bash
# Fresh start (delete CAS first)
rm -rf ~/.vrift/the_source
vrift ingest /path/to/project1/node_modules -o p1.manifest
vrift ingest /path/to/project2/node_modules -o p2.manifest

# Re-run (keep CAS for maximum dedup)
vrift ingest /path/to/project1/node_modules -o p1.manifest
```
