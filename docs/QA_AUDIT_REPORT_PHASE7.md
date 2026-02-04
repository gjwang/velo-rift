# QA Audit Report: Phase 7 Architectural Alignment (Vision E2E)

## 📋 Executive Summary
This report details critical architectural deviations and stability regressions discovered during the Phase 7 "Vision E2E" stress testing (`v-inception-stress.sh`). While core ingestion components (Phantom Mode) function correctly at a physical level, the system exhibits severe brittleness under industrial-scale concurrency and environment variations.

---

## 🛑 Critical Failure Proof: The Concurrency Deadlock
**Scenario**: 100 concurrent `cat` processes performing nested VFS opens against a project with 5,000 virtual blobs.
**Result**: **100% Hang Rate**.
**Forensic Signal**:
- Processes enter `UE` (Uninterruptible Sleep) status.
- IPC socket `/tmp/vrift.sock` remains bound but non-responsive.
- Pattern Matches: `Pattern 2868 (Shim-Daemon IPC Deadlock)`.

> [!CAUTION]
> This hang prevents Velo Rift from being used in high-parallel build environments (e.g., `make -j100` or `bazel`).

---

## ⚠️ Architectural Deviations & Sensitivity

### 1. Hex Encoding Inconsistency (RFC-0039 §6)
**Issue**: `CasStore::hash_to_hex` and CLI encoding logic may produce inconsistent casing (Upper vs Lower), leading to `vriftd` blind spots during `scan_cas_root`.
**Evidence**: Physical files exist in `blake3/ab/cd/...`, but daemon status reports 0 blobs if casing does not match the scanning glob.

### 2. Path Resolution Brittleness
**Issue**: `VR_THE_SOURCE` (CAS Root) must be **absolute** for consistent sharding lookups.
**Evidence**: Relative paths lead to disparate sharding prefixes if the daemon and CLI have different working directories or relative base context.

### 3. VDir Warm-up Race Condition
**Issue**: `vriftd` performs a `scan_cas_root` on startup. If ingestion occurs immediately after, the daemon index might not be hot, leading to "No such file" errors during projection.
**Verification**: A 3-second delay in `v-inception-stress.sh` mitigated the 0-blob report, proving a lack of "live sync" or watch-based indexing in the current v3.2 implementation.

---

## 🛠️ Recommendations for Dev Team
1. **IPC Hardening**: Implement non-blocking or multiplexed IPC in the shim to prevent `UE` state hangs.
2. **Standardized Normalization**: Enforce `lowercase()` hex and `canonicalize()` paths at the `vrift-manifest` level (Deep Audit recommendation).
3. **Live Indexing**: Replace the early `scan_cas_root` with a `notify_blob` based re-indexing system that is resilient to ingest timing.

---

## 🧪 Verification Artifacts
- **Test Script**: `tests/qa_v2/v-inception-stress.sh`
- **Diagnostic Logs**: Available at `/tmp/vrift_endgame_stress/vriftd.log`

