# VRift Performance Report

Generated: 2026-02-12 01:05

## Key Metrics

| Dataset | Files | Blobs | Dedup | Speed |
|---------|-------|-------|-------|-------|
| xsmall | 16,667 | 13,773 | 17.4% | 4,411/s |
| small | 23,982 | 20,581 | 14.2% | 5,272/s |
| medium | 61,937 | 51,569 | 16.7% | 5,642/s |

## Deduplication Efficiency

Space savings from content-addressable storage:

- **xsmall**: 16,667 files -> 13,773 blobs (17.4% dedup, ~38.6 MB saved)
- **small**: 23,982 files -> 20,581 blobs (14.2% dedup, ~49.0 MB saved)
- **medium**: 61,937 files -> 51,569 blobs (16.7% dedup, ~84.9 MB saved)

## Re-ingest Performance (CI Cache Hit)

Performance when CAS already contains content:

- **xsmall**: 33,970 files/sec (7.7x faster than first ingest)
- **small**: 39,140 files/sec (7.4x faster than first ingest)
- **medium**: 33,973 files/sec (6.0x faster than first ingest)