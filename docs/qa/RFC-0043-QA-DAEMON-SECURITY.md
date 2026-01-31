# RFC-0043 Daemon Security Review

This document performs an adversarial audit of the `vrift-daemon` implementation against the security requirements of RFC-0043.

## Critical Vulnerabilities

### 1. Arbitrary File Ownership Change (Privilege Escalation)
> [!CAUTION]
> **Severity**: P0 (Critical)
> **Endpoint**: `VeloRequest::Protect { path, owner, .. }`
> **Vulnerability**: The daemon performs `chown` on arbitrary paths provided by the client without validation or sandboxing.
> **Impact**: If the daemon runs as root (or with `CAP_CHOWN`), a local user can take ownership of sensitive system files (e.g., `/etc/shadow`, `/usr/bin/sudo`).

### 2. OOM denial of Service (Resource Exhaustion)
> [!WARNING]
> **Severity**: P1 (High)
> **Endpoint**: IPC Header Processing
> **Vulnerability**: The daemon reads a 4-byte length header and allocates a buffer of that size immediately: `let mut buf = vec![0u8; len];`.
> **Impact**: A malicious client can send a length of `0xFFFFFFFF`, causing the daemon to attempt a 4GB allocation and crash with Out-Of-Memory.

### 3. Unauthorized Task Spawning (RCE/Privilege Escalation)
> [!CAUTION]
> **Severity**: P0 (Critical)
> **Endpoint**: `VeloRequest::Spawn`
> **Vulnerability**: The daemon allows clients to spawn arbitrary commands with arbitrary environment variables.
> **Impact**: Any local user can execute commands as the `vrift` (or `root`) user. This bypasses all intended access controls.

### 4. Path Traversal
> [!WARNING]
> **Severity**: P1 (High)
> **Endpoint**: `VeloRequest::Protect`
> **Vulnerability**: Paths are not normalized or checked against a base directory.
> **Impact**: Attackers can access files outside the intended CAS/Project scope using `../` sequences.

## Architectural Misalignments

- **RFC-0043 Requirement**: "Secure CAS ownership isolation".
- **Implementation**: The daemon provides *less* security than direct mode by introducing an unsecured privileged IPC bridge that can be easily exploited for host-level compromise.

## Recommended Fixes

1. **Path Sandboxing**: Canonicalize all paths and ensure they reside within the project root or CAS root.
2. **IPC Guardrails**: Limit the maximum allowed IPC message size (e.g., 64MB) and validate headers before allocation.
3. **Authentication**: Use `SO_PEERCRED` to identify the UID/GID of the connecting process and only allow operations on files owned by that user.
4. **Restricted Shell**: For `Spawn`, restrict commands to a pre-approved whitelist or ensure they run with the caller's privileges (e.g., via `setuid`).
