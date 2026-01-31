# RFC-0043 Functional Alignment Review

This document evaluates the compliance of the current `vrift-daemon` implementation with the functional requirements specified in RFC-0043.

## Requirement vs. Implementation Traceability

| Requirement | ID | Status | Implementation Notes |
|-------------|----|--------|----------------------|
| Secure CAS ownership isolation | R1 | **Partial** | Daemon logic exists, but user isolation (peer credentials) is missing. |
| Multi-user CAS sharing | R2 | **Partial** | System-wide socket exists, but no quota or user-prefixing logic. |
| Live Ingest via IPC | R3 | **FAIL** | Daemon receives `Protect` but NOT `CasInsert`. Index is out-of-sync. |
| Zero-privilege client operations | R4 | **Pass** | CLI interacts with daemon via Unix socket correctly. |
| CAS Warm-up Scan | R5 | **Pass** | Background scan works on startup. |
| systemd Integration | R6 | **Missing** | No service files found in codebase yet. |

## Functional Gaps (Standard Environment)

1. **Missing Live Indexing**: CLI fails to send `CasInsert` IPC messages, meaning the Daemon is unaware of new Tier-2 blobs in real-time.
2. **Platform Compatibility (macOS)**: The "Iron Law" (immutability) is NOT enforced on macOS because the implementation uses Linux-specific `chattr`. It should be updated to use `chflags uchg`.
3. **Implicit Protection**: 444 permissions are correctly applied.

## Basic Security Baselining

- **Invariant**: CAS blobs must NOT be writable by the user who ingested them if the daemon is managing the CAS.
- **Verification**: Ingest a file, then attempt `echo "corrupt" >> [CAS_PATH]`. It should fail with `Permission Denied`.
- **Result**: **SUCCESS**. Standard 444 permissions are correctly enforced by the ingestion logic.
