# VRift Performance Report

Generated: 2026-02-09 03:26

## Key Metrics

| Dataset | Files | Blobs | Dedup | Speed |
|---------|-------|-------|-------|-------|
| xsmall | 16,667 | 13,776 | 17.3% | 3,535/s |
| small | 23,982 | 20,566 | 14.2% | 2,431/s |

## Deduplication Efficiency

Space savings from content-addressable storage:

- **xsmall**: 16,667 files -> 13,776 blobs (17.3% dedup, ~38.6 MB saved)
- **small**: 23,982 files -> 20,566 blobs (14.2% dedup, ~49.3 MB saved)

## Re-ingest Performance (CI Cache Hit)

Performance when CAS already contains content:

- **xsmall**: 8,039 files/sec (2.3x faster than first ingest)
- **small**: 8,528 files/sec (3.5x faster than first ingest)