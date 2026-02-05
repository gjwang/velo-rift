# VRift Performance Report

Generated: 2026-02-05 20:52

## Key Metrics

| Dataset | Files | Blobs | Dedup | Speed |
|---------|-------|-------|-------|-------|
| xsmall | 16,667 | 13,783 | 17.3% | 165/s |
| small | 23,982 | 20,590 | 14.1% | 129/s |

## Deduplication Efficiency

Space savings from content-addressable storage:

- **xsmall**: 16,667 files -> 13,783 blobs (17.3% dedup, ~38.5 MB saved)
- **small**: 23,982 files -> 20,590 blobs (14.1% dedup, ~48.9 MB saved)

## Re-ingest Performance (CI Cache Hit)

Performance when CAS already contains content:

- **xsmall**: 10,918 files/sec (66.4x faster than first ingest)
- **small**: 12,312 files/sec (95.3x faster than first ingest)