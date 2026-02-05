# VRift Performance Report

Generated: 2026-02-05 23:20

## Key Metrics

| Dataset | Files | Blobs | Dedup | Speed | Total Time |
|---------|-------|-------|-------|-------|------------|
| Small | 23,948 | 20,590 | 14.0% | 3,894/s | 6.15s |
| Medium | 61,865 | 51,545 | 16.7% | 3,870/s | 15.99s |
| Large | 68,308 | 50,691 | 25.8% | 3,722/s | 18.35s |
| XLarge | 86,358 | 63,666 | 26.3% | 4,148/s | 20.82s |

## Throughput Analysis

Peak performance: **4,148 files/sec** (XLarge dataset, 86K files)

Consistent performance: **~3,700-4,100 files/sec** across all dataset sizes

## Deduplication Efficiency

Space savings from content-addressable storage:

| Dataset | Original Files | Unique Blobs | Dedup Rate | Space Saved |
|---------|----------------|--------------|------------|-------------|
| Small | 23,948 | 20,590 | 14.0% | 4.65 MB |
| Medium | 61,865 | 51,545 | 16.7% | 24.81 MB |
| Large | 68,308 | 50,691 | 25.8% | 38.91 MB |
| XLarge | 86,358 | 63,666 | 26.3% | 51.76 MB |

**Total space saved: ~120 MB across all datasets**

## Re-ingest Performance (CAS Hit)

When content already exists in CAS (100% deduplication):

| Dataset | Speed |
|---------|-------|
| 103 files | 10,300/s |

## Daemon Mode (`--via-daemon`)

The new daemon mode delegates ingest to `vriftd` for unified CAS management:

```bash
./target/release/vrift ingest /path --via-daemon --output manifest.bin
```

Performance is equivalent to direct mode with added benefits:
- Shared CAS across multiple projects
- Background GC and optimization
- Reduced startup overhead for subsequent operations

## Hardware

- **CPU**: Apple M-series (10 cores)
- **Threads**: 4 (configurable via `--threads`)
- **Storage**: APFS SSD

## Running Benchmarks

```bash
./scripts/benchmark_parallel.sh
```