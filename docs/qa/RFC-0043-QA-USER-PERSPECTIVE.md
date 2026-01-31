# User-Perspective Functional Alignment: RFC-0039 & RFC-0043

This document evaluates Velo Rift™'s implementation from the perspective of an end-user (developer/devops) and identifies how well the technical features serve real-world usage scenarios.

## Scenario 1: The "Invisible" Ingest (Background Efficiency)

**User Goal**: I just want to install dependencies (e.g., `npm install`) and have Velo Rift handle the deduplication without slowing me down or needing manual intervention.

| Requirement | Implementation Status | User Impact |
|-------------|-----------------------|-------------|
| **Zero-Impact Performance** | ✅ HIGH | Standard ingest is fast enough (14k+ files/sec). |
| **Real-time Indexing** | ❌ **FAIL** | CLI does not notify Daemon via `CasInsert`. Verified: `test_standard_ingest_ipc.sh` logs. |
| **Automatic Protection** | ✅ PASS | Permissions are set to 444 during ingest. |

**Gap**: Without real-time index synchronization, the "collaboration" benefit of a shared CAS is delayed, causing redundant downloads if User B runs a build shortly after User A.

---

## Scenario 2: Development Friction (Break-Before-Write)

**User Goal**: I need to tweak a file in `node_modules` (or any projected dir) for debugging. It should work like a normal file.

| Requirement | Implementation Status | User Impact |
|-------------|-----------------------|-------------|
| **Seamless Modification** | ✅ PASS | Shim intercepts write and performs CoW. |
| **State Persistence** | ❌ **FAIL** | Manifest NOT updated after CoW. Verified: `test_manifest_convergence.sh` (Desync detected). |
| **IDE Compatibility** | ⚠️ UNKNOWN | Many IDEs (VSCode/JetBrains) perform complex Atomic-Saves. The shim must intercept `rename`, `truncate`, and `unlink` to be truly robust. |

**Gap**: Manifest desync after CoW is a "Time Bomb". The system "forgets" that the user made a local copy.

---

## Scenario 3: Multi-User Collaboration (Shared Infrastructure)

**User Goal**: A shared development server (e.g., dev-server for a team). I want to benefit from the global CAS without other users messing with my manifests or reading my private code.

| Requirement | Implementation Status | User Impact |
|-------------|-----------------------|-------------|
| **Shared CAS Read** | ✅ PASS | Global CAS paths are predictable. |
| **Metadata Protection** | ❌ **FAIL** | Verified: `test_user_isolation.sh`. Daemon lacks peer credential logic. |
| **Action Isolation** | ❌ **FAIL** | Verified: `trigger_exploit.rs`. Any user can spawn as daemon. |

**Gap**: The current Daemon implementation is a security liability in multi-user environments. It lacks the "Trust Boundary" required for shared infrastructure.

---

## Summary of Priority Gaps (User Centric)

1. **Manifest Reconciler**: The Shim or Daemon MUST update the local `manifest.bin` when CoW occurs.
2. **IPC Peer Credentials**: The Daemon MUST verify user identity (peer credentials) before performing `Protect` or `Spawn`.
3. **Proactive Ingest Sync**: CLI MUST send `CasInsert` to the Daemon to ensure immediate global availability.
