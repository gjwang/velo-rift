# VRift Performance Report

Generated: 2026-02-09

## Key Metrics (First Ingest)

Fresh CAS, real file I/O (hash + link + manifest write):

| Dataset | Files | Blobs | Dedup | Speed | Total Time |
|---------|-------|-------|-------|-------|------------|
| XSmall | 16,667 | 13,772 | 17.4% | 3,424/s | 4.87s |
| Small | 23,982 | 20,574 | 14.2% | 3,795/s | 6.32s |
| Medium | 61,865 | 51,545 | 16.7% | 3,870/s | 15.99s |
| Large | 68,308 | 50,691 | 25.8% | 3,722/s | 18.35s |
| XLarge | 86,358 | 63,666 | 26.3% | 4,148/s | 20.82s |

Consistent throughput: **~3,400-4,200 files/sec** across all dataset sizes.

## Re-ingest Performance (CAS Hit)

When CAS already contains all content (100% deduplication):

| Dataset | Files | Re-ingest Speed | Speedup |
|---------|-------|-----------------|---------|
| XSmall | 16,667 | 6,595/s | 1.9x |
| Small | 23,982 | 6,399/s | 1.7x |

Re-ingest skips all file writes (hash-only + existence check), achieving **~1.7-1.9x** speedup.

## Deduplication Efficiency

Space savings from content-addressable storage (BLAKE3 + 3-level sharding):

| Dataset | Original Size | Unique Blobs | Dedup Rate | Space Saved |
|---------|---------------|--------------|------------|-------------|
| XSmall | 222.3 MB | 13,772 | 17.4% | 38.6 MB |
| Small | 345.8 MB | 20,574 | 14.2% | 49.1 MB |
| Medium | 505.9 MB | 51,545 | 16.7% | 24.8 MB |
| Large | 464.5 MB | 50,691 | 25.8% | 38.9 MB |
| XLarge | ~600 MB | 63,666 | 26.3% | 51.8 MB |

## Architecture

All ingest operations route through the `vriftd` daemon via IPC:

```
CLI (--the-source-root) → IPC → vriftd → streaming_ingest → CAS
```

CAS root precedence: `CLI arg > env (VR_THE_SOURCE) > config.toml > default (~/.vrift/the_source)`

## Hardware

- **CPU**: Apple M-series (10 cores)
- **Threads**: 4 (configurable via `--threads`)
- **Storage**: APFS SSD

## Running Benchmarks

```bash
# Quick (XSmall + Small)
python3 scripts/benchmark_suite.py --quick

# Full (all datasets)
python3 scripts/benchmark_suite.py

# Shell script (single run, no re-ingest)
./scripts/benchmark_parallel.sh
```