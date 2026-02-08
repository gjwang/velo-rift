# VRift Performance Report

Generated: 2026-02-09

## Key Metrics (First Ingest)

Fresh CAS, real file I/O (hash + link + manifest write):

| Dataset | Files | Size | Blobs | Dedup | Speed |
|---------|-------|------|-------|-------|-------|
| XSmall | 16,667 | 222 MB | 13,772 | 17.3% | 3,587/s |
| Small | 23,982 | 346 MB | 20,574 | 14.2% | 3,873/s |
| Medium | 61,756 | 507 MB | 51,545 | 16.5% | 3,116/s |
| Large | 68,383 | 465 MB | 50,691 | 25.9% | 3,639/s |
| XXLarge | 193,851 | 2.0 GB | ~136k | 29.7% | 4,090/s |

Consistent throughput: **~3,100-4,100 files/sec** across all dataset sizes (16k-194k files).

## Re-ingest Performance (CAS Hit)

When CAS already contains all content (100% deduplication):

| Dataset | Files | Re-ingest Speed | Speedup |
|---------|-------|-----------------|---------|
| XSmall | 16,667 | 5,719/s | 1.6x |
| Small | 23,982 | 4,423/s | 1.1x |
| Medium | 61,756 | 4,892/s | 1.6x |
| Large | 68,383 | 5,364/s | 1.5x |
| XXLarge | 193,851 | 6,238/s | 1.5x |

Re-ingest skips all file writes (hash-only + existence check), achieving **~1.1-1.6x** speedup.

## Deduplication & Space Savings

| Dataset | Original | After CAS | Saved | Rate |
|---------|----------|-----------|-------|------|
| XSmall | 222 MB | 219 MB | 3.1 MB | 1% |
| Small | 346 MB | 341 MB | 4.8 MB | 1% |
| Medium | 507 MB | 482 MB | 25 MB | 5% |
| Large | 465 MB | 416 MB | 48 MB | 10% |
| XXLarge | 2.0 GB | 1.7 GB | 324 MB | 16% |

Larger datasets show higher dedup rates due to more shared transitive dependencies.

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

# Full (all datasets including XXLarge ~194k files)
python3 scripts/benchmark_suite.py

# Shell script (single run, no re-ingest)
./scripts/benchmark_parallel.sh
```