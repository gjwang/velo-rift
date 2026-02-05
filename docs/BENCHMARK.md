# VRift Performance Report

Generated: 2026-02-05 21:40

## Key Metrics

| Dataset | Files | Blobs | Dedup | Speed |
|---------|-------|-------|-------|-------|
| xsmall | 16,667 | 13,783 | 17.3% | 4,468/s |
| small | 23,982 | 20,590 | 14.1% | 3,143/s |

## Deduplication Efficiency

Space savings from content-addressable storage:

- **xsmall**: 16,667 files -> 13,783 blobs (17.3% dedup, ~38.5 MB saved)
- **small**: 23,982 files -> 20,590 blobs (14.1% dedup, ~48.9 MB saved)

## Re-ingest Performance (CI Cache Hit)

Performance when CAS already contains content:

- **xsmall**: 17,922 files/sec (4.0x faster than first ingest)
- **small**: 21,223 files/sec (6.8x faster than first ingest)