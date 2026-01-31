# RFC-0041: CAS Garbage Collection and Multi-Project Management

**Status**: Draft  
**Authors**: VRift Team  
**Created**: 2026-01-31  
**Supersedes**: None

---

## Abstract

This RFC proposes a garbage collection (GC) and project management system for VRift's Content-Addressable Store (CAS). It addresses the challenge of safely managing CAS blobs when multiple projects share a global store, ensuring orphaned blobs are cleaned up without breaking active projects.

---

## Motivation

### Problem Statement

VRift's power comes from cross-project deduplication via a shared CAS. However, this creates a management challenge:

```
~/.vrift/the_source/
├── blob_A  # Referenced by project1, project2
├── blob_B  # Only referenced by project1  
├── blob_C  # Orphan - no manifest references it
└── blob_D  # Hard-linked, permission restrictions
```

**Current Issues**:
1. No built-in way to clean orphaned blobs
2. Manual `rm -rf` fails on hard-linked files due to permissions
3. No visibility into which blobs belong to which projects
4. No safe way to "uninstall" a project without affecting others

### Use Cases

| Scenario | Need |
|----------|------|
| **Disk pressure** | Clean orphaned blobs to reclaim space |
| **Project removal** | Safely remove a project's blobs without breaking others |
| **Fresh start** | Wipe entire CAS for clean testing environment |
| **Audit** | Understand which projects use how much space |

---

## Design

### Core Components

#### 1. Manifest Registry

A central registry tracking all known manifests with UUID-based identification:

```
~/.vrift/registry/
├── manifests.json           # Active manifest list (SSOT)
└── manifests/
    └── <uuid>.manifest      # Cached copy of manifest (for GC when project deleted)
```

**manifests.json**:
```json
{
  "version": 1,
  "manifests": {
    "a1b2c3d4-e5f6-7890-abcd-ef1234567890": {
      "source_path": "/home/user/project1/.vrift.manifest",
      "source_path_hash": "blake3:abc123...",
      "project_root": "/home/user/project1",
      "registered_at": "2026-01-31T12:00:00Z",
      "last_verified": "2026-01-31T18:00:00Z",
      "status": "active"
    },
    "b2c3d4e5-f6a7-8901-bcde-f23456789012": {
      "source_path": "/home/user/project2/.vrift.manifest",
      "source_path_hash": "blake3:def456...",
      "project_root": "/home/user/project2",
      "registered_at": "2026-01-31T14:00:00Z",
      "last_verified": "2026-01-31T18:00:00Z",
      "status": "active"
    }
  }
}
```

**Key Design Decisions**:

| Issue | Solution |
|-------|----------|
| **Filename collision** | Use UUID as primary key, not project name |
| **Project deleted** | Detect via `source_path` existence check; mark `status: "stale"` |
| **Manifest moved** | Use `source_path_hash` to detect content changes |
| **Offline GC** | Cache manifest copy in `manifests/<uuid>.manifest` |

**Stale Project Handling**:

```
gc --verify:
  1. For each registered manifest:
     - Check if source_path exists
     - If not: mark status = "stale"
  2. Stale manifests still protect blobs until explicitly removed
  3. User can run: vrift gc --prune-stale to remove stale entries
```

**Example Flow**:
```bash
# User deletes project directory
rm -rf /home/user/project1

# Next GC detects stale manifest
vrift gc
# Output:
#   ⚠️  Stale manifest: project1 (source path deleted)
#   🗑️  Orphaned blobs: 0 (stale manifest still protecting blobs)
#
#   Run `vrift gc --prune-stale` to remove stale manifests first.

# User confirms stale removal
vrift gc --prune-stale
# Output:
#   Removed stale manifest: a1b2c3d4-... (project1)
#   Orphaned blobs now available for cleanup.

# Then clean orphans
vrift gc --delete
```

#### 2. Command: `vrift gc`

**Behavior**: Scan all registered manifests, identify unreferenced blobs, delete them.

```bash
# Dry run (default) - show what would be deleted
vrift gc

# Actually delete orphaned blobs
vrift gc --delete

# Aggressive mode - only keep blobs from specified manifests
vrift gc --only manifest1.manifest manifest2.manifest --delete
```

**Algorithm**:
```
1. Load all registered manifests
2. Build set of all referenced blob hashes
3. Walk CAS directory, identify blobs not in reference set
4. Delete orphans (if --delete) or report (dry run)
```

**Output**:
```
GC Analysis:
  📁 Registered manifests: 3
  🗄️  Total CAS blobs: 45,231
  ✅ Referenced blobs: 42,108
  🗑️  Orphaned blobs: 3,123 (142 MB)

Run with --delete to clean orphans.
```

#### 3. Command: `vrift clean`

**Behavior**: Project-level cleanup operations.

```bash
# Unregister a project (marks its unique blobs as orphans)
vrift clean --unregister /path/to/project

# Force clean entire CAS (dangerous!)
vrift clean --all --force

# Clean CAS with permission fix (chmod before rm)
vrift clean --all --force --fix-perms
```

#### 4. Command: `vrift status`

Enhanced status with per-project breakdown:

```bash
vrift status
```

**Output**:
```
VRift CAS Status:

  CAS Location: ~/.vrift/the_source
  Total Size:   1.48 GB
  Total Blobs:  115,363

  Registered Projects:
  ┌─────────────────────────────────────────────────────────────────┐
  │ Project        │ Files    │ Unique Blobs │ Shared │ Size       │
  ├─────────────────────────────────────────────────────────────────┤
  │ project1       │ 16,647   │ 13,783       │ 0      │ 222 MB     │
  │ project2       │ 23,948   │ 6,816        │ 6,967  │ +122 MB    │
  │ project3       │ 61,703   │ 30,947       │ 13,829 │ +365 MB    │
  └─────────────────────────────────────────────────────────────────┘

  Orphaned Blobs: 0 (run `vrift gc` to check)
```

---

## Hard Link Permission Handling

Hard-linked files inherit restrictive permissions. Fix strategy:

```rust
fn fix_permissions(cas_root: &Path) -> Result<()> {
    for entry in WalkDir::new(cas_root) {
        let path = entry?.path();
        if path.is_file() {
            // Add write permission
            let mut perms = fs::metadata(&path)?.permissions();
            perms.set_mode(perms.mode() | 0o200);
            fs::set_permissions(&path, perms)?;
        }
    }
    Ok(())
}
```

---

## CLI Interface Summary

| Command | Description | Safety |
|---------|-------------|--------|
| `vrift gc` | Dry-run GC analysis | Safe |
| `vrift gc --delete` | Delete orphaned blobs | Safe (only orphans) |
| `vrift gc --only <manifests> --delete` | Keep only specified | Dangerous |
| `vrift clean --unregister <project>` | Remove project registration | Safe |
| `vrift clean --all --force` | Wipe entire CAS | Destructive |
| `vrift clean --all --force --fix-perms` | Wipe with perm fix | Destructive |
| `vrift status` | Show CAS and project status | Safe |

---

## Implementation Phases

### Phase 1: Basic GC (MVP)
- [ ] Implement manifest registry (`~/.vrift/registry/manifests.json`)
- [ ] `vrift ingest` auto-registers manifests
- [ ] `vrift gc` scans and reports orphans
- [ ] `vrift gc --delete` removes orphans

### Phase 2: Project Management
- [ ] `vrift clean --unregister <project>`
- [ ] `vrift status` with per-project breakdown
- [ ] Permission fix utilities

### Phase 3: Advanced Features
- [ ] Reference counting per-blob
- [ ] Incremental GC (track last GC time)
- [ ] CAS compaction (defragmentation)

---

## Alternatives Considered

### 1. Per-Blob Reference Counting
Store reference count with each blob. **Rejected** because:
- Adds complexity to ingest/delete paths
- Requires atomic updates
- Registry approach is simpler for MVP

### 2. Embedded Manifest in CAS
Store manifests inside CAS itself. **Rejected** because:
- Makes GC self-referential
- Harder to enumerate active projects

### 3. FUSE-Level Tracking
Track references at VFS level. **Rejected** because:
- Requires FUSE to be running
- Overkill for offline GC needs

---

## Open Questions

1. **Manifest discovery**: Should `vrift gc` auto-discover manifests in common locations?
2. **Stale manifests**: How to handle manifests that point to deleted projects?
3. **Concurrent access**: Locking strategy during GC?

---

## References

- RFC-0039: Transparent Virtual Projection
- Git's garbage collection: `git gc`
- Docker's image prune: `docker image prune`
