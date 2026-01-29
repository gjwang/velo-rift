# Velo Technical Architecture Specification

> **Status**: Living Document  
> **Language**: English Only  
> **Scope**: Low-level implementation details, directory structures, data schemas, and internal protocols.

---

## 1. System Directory Layout (Physical View)

To achieve the "Hard Link Farm" efficiency and "OverlayFS" illusion, Velo enforces a strict physical layout on the Host Machine.

### 1.1 The RAM Disk Root
All tenant runtime data lives in a high-performance memory-backed location.
*   **Path**: `/mnt/velo_ram_disk` (Mounted as `tmpfs`)
*   **Purpose**: Ensures `link()` (hard links) work between the Warehouse and Tenant Roots.

### 1.2 Structure Hierarchy
```text
/mnt/velo_ram_disk/
├── pool/                       # The "Warehouse" (Shared Read-Only)
│   ├── numpy-1.26.0/           # Exploded package trees
│   │   ├── numpy/
│   │   └── numpy-1.26.0.dist-info/
│   └── torch-2.1.0/
│
├── tenants/                    # Tenant Runtime Roots (Ephemeral)
│   ├── tenant_A/
│   │   ├── upper/              # OverlayFS UpperDir (Private Writes)
│   │   ├── work/               # OverlayFS WorkDir
│   │   └── merged/             # The Tenant's Rootfs (Pivot Root Target)
│   └── tenant_B/
│
└── cas_store/                  # The Raw Blob Store (Optional: can be on NVMe)
    ├── a8/
    │   └── f9c1...             # Raw Content BLOB (BLAKE3)
    └── b2/
        └── d3e4...
```

### 1.3 Persistent Storage (NVMe/Disk)
*   **Path**: `/var/velo/meta.db` -> **LMDB** file for Git Metadata.
*   **Path**: `/var/velo/cas_cache/` -> Persistent cache for Cold Blobs.

---

## 2. Naming, Addressing & IDs

Velo uses a "Content-Addressable" everything approach. ID collision is impossible by design.

### 2.1 Hash Standard
*   **Algorithm**: **BLAKE3**.
*   **Length**: 256-bit (32 bytes).
*   **Encoding**: Hex string (64 chars) for display; Raw bytes for storage.

### 2.2 ID Formats
| Type | Prefix | Format | Example |
| :--- | :--- | :--- | :--- |
| **Blob ID** | `blob:` | `blake3:{hash}` | `blob:a8f9c1...` |
| **Tree ID** | `tree:` | `blake3:{hash}` | `tree:d4e5f6...` |
| **Commit ID** | `commit:` | `sha1:{git_hash}` | `commit:998877...` |
| **Tenant Ref** | `ref:` | `refs/tenants/{id}/HEAD` | `refs/tenants/user_123/HEAD` |
| **uv Lock Hash** | `uvlock:` | `sha256:{hash}` | `uvlock:7f8a...` (Derived from `uv.lock` content) |

---

## 3. Data Structures & Protocols

### 3.1 `velo.lock` (The Execution Spec)
This is the compiled "Bytecode" derived from `uv.lock`. It bridges the intent (Package Name) to the physical capability (Tree Hash).

```json
{
  "meta": {
    "engine": "velo-native-v1",
    "generated_at": 1706448000,
    "uv_lock_hash": "sha256:7f8a...",
    "target_platform": "linux_x86_64_gnu"
  },
  "roots": {
    "site_packages": {
      "mount_point": "/app/.venv/lib/python3.11/site-packages",
      "tree_hash": "tree:root_site_packages_merged_hash"
    }
  },
  "packages": {
    "numpy": {
      "version": "1.26.0",
      "source_tree": "tree:numpy_1.26.0_hash",
      "dist_info_tree": "tree:numpy_1.26.0_dist_info_hash"
    },
    "pandas": {
      "version": "2.1.0",
      "source_tree": "tree:pandas_2.1.0_hash"
    }
  }
}
```

### 3.2 In-Memory Git Schema (Within LMDB)
We "flatten" the Git graph into Key-Value pairs for O(1) access.

*   **Database 1: Objects**
    *   **Key**: `[Hash (20 bytes)]`
    *   **Value**: `[Type (1 byte)] + [Payload]`
*   **Database 2: References**
    *   **Key**: `refs/tenants/A/HEAD`
    *   **Value**: `[Commit Hash]`

### 3.3 The "Pointer Blob" Structure
Instead of storing file content in Git, we store a pointer to the CAS.

```rust
#[repr(C)]
struct VeloBlob {
    cas_hash: [u8; 32],  // BLAKE3 Hash of physical content
    size: u64,           // File size in bytes
    flags: u8,           // e.g., IsExecutable
}
```

---

## 4. The "Warehouse" Model (Implementation Logic)

How Velo achieves "Instant Install" and "Zero-Copy Sharing" using Hard Links.

### 4.1 The Pre-requisite
The **Host Warehouse** (`/mnt/velo_ram_disk/pool`) and the **Tenant Directory** (`/mnt/velo_ram_disk/tenants/A`) **MUST** reside on the same filesystem (Mountpoint). This allows `link()` syscalls to work.

### 4.2 The Construction Algorithm (O(1) Install)
When `velo.lock` says "Tenant A needs Numpy 1.26":

1.  **Lookup**: Velo checks `pool/numpy-1.26.0/`.
2.  **Link Farm Generation**:
    *   Velo creates destination dir: `tenants/A/lower/site-packages/numpy/`.
    *   For each file in `pool/numpy-1.26.0/numpy/`:
        *   `link(src="/pool/.../core.so", dst="/tenants/A/.../core.so")`.
    *   *Result*: The tenant has a physical file entry, but it points to the same inode as the pool.
3.  **Overlay Mount**:
    *   The `lower` directory (full of hard links) becomes the read-only base of the OverlayFS.

---

## 5. Isolation Implementation (The Sandwich Mount)

Details of the syscall sequence to build the "Standard VM Illusion".

### 5.1 The Layer Stack
1.  **LowerDir 1 (Base OS)**: `/opt/images/debian-slim` (Contains `glibc`, `python3`, `bash`).
2.  **LowerDir 2 (Injects)**: `/mnt/velo_ram_disk/tenants/A/lower` (The Hard Link Farm constructed above).
3.  **UpperDir**: `/mnt/velo_ram_disk/tenants/A/upper` (Private Tmpfs).

### 5.2 The Mount Sequence
```bash
# 1. Create Tenant Workspace
mkdir -p /mnt/velo_ram_disk/tenants/A/{upper,work,merged,lower}

# 2. Populate Lower (The Link Farm) via Velo Engine
velo-internal populate-links --lock velo.lock --target .../lower

# 3. Mount OverlayFS
mount -t overlay overlay \
    -o lowerdir=/mnt/velo_ram_disk/tenants/A/lower:/opt/images/debian-slim \
    -o upperdir=/mnt/velo_ram_disk/tenants/A/upper \
    -o workdir=/mnt/velo_ram_disk/tenants/A/work \
    /mnt/velo_ram_disk/tenants/A/merged

# 4. Bind Mount /dev/shm (For shared memory communication)
mount --bind /dev/shm/tenant_A /mnt/velo_ram_disk/tenants/A/merged/dev/shm
```

---

## 6. Distribution Architecture (Tiered Caching)

The traffic flow for "Miss & Backfill".

### 6.1 The Hierarchy
*   **L1: Host Cache** (`/mnt/velo_ram_disk/pool`)
    *   Serving latency: **< 1ms** (Link)
    *   Hit rate goal: 95%
*   **L2: Region Blob Store** (Internal S3 / MinIO)
    *   Serving latency: **10-50ms** (LAN Stream)
    *   Format: Compressed Velo Trees (e.g., `numpy-1.26.tar.zst` containing CAS-ready structures).
*   **L3: External Ecosystem** (PyPI / GitHub)
    *   Serving latency: **Seconds**
    *   Action: Ingest Workers download, verify, re-pack into Velo/CAS format, push to L2.

### 6.2 The "Backfill" Protocol
When a Tenant requests a `tree_hash` not present in L1:
1.  **Pause**: Tenant spawn is paused.
2.  **Fetch**: Host requests `tree_hash` from L2.
3.  **Stream**: L2 streams the specialized Velo archive.
4.  **Unpack**: Host unpacks directly into `/mnt/velo_ram_disk/pool`.
5.  **Resume**: Link Farm generation proceeds.

---

## 7. Shared Memory Security Details

### 7.1 "Read-Only" Enforcement
*   **Memory Object**: Created via `memfd_create`.
*   **Sealing**: `fcntl(F_SEAL_WRITE | F_SEAL_SHRINK | F_SEAL_GROW)`.
*   **Capability Downgrade**:
    *   Host holds: `fd_rw` (Sealed).
    *   Tenant receives: `fd_ro` (Created via `open("/proc/self/fd/...", O_RDONLY)`).
*   **Tenant Mapping**: Must use `mmap(..., PROT_READ)`. `PROT_WRITE` triggers `EPERM`.

### 7.2 Safety Valves
*   **Cgroups v2**: Hard limits on memory usage (`memory.max`) to prevent DoS via massive allocations in UpperDir.
*   **Seccomp**: `SCMP_ACT_ERRNO` for `mprotect` on mapped shared regions.

---

## 8. Multi-Tenant Isolation Architecture

Velo provides a complete "VM illusion" where tenants can perform any operation (pip install, apt, etc.) within a fully isolated environment.

### 8.1 Alpine Linux Security Shim

Alpine Linux serves as the base rootfs layer for tenant isolation:

*   **Rootfs Template**: `/opt/images/alpine-base` (Minimal ~5MB image)
*   **Why Alpine**: Musl libc + BusyBox = smallest attack surface, fast pivot.
*   **Role**: Provides standard POSIX environment (`/bin`, `/lib`, `/etc`) without glibc bloat.

**Alternative**: Debian-slim for full glibc compatibility when required.

### 8.2 Namespace Isolation Stack

Each tenant runs in isolated Linux namespaces:

```c
// Namespace Creation Sequence
unshare(
    CLONE_NEWNS   |  // Mount namespace (isolated filesystem view)
    CLONE_NEWPID  |  // PID namespace (process isolation)
    CLONE_NEWNET  |  // Network namespace (network isolation)
    CLONE_NEWIPC  |  // IPC namespace (shared memory isolation)
    CLONE_NEWUSER    // User namespace (UID/GID mapping)
);
```

**Post-Unshare Actions**:
1. `pivot_root(merged_view, old_root)` — Switch rootfs
2. `umount(old_root, MNT_DETACH)` — Hide host filesystem
3. Mount pseudo-filesystems: `/proc`, `/sys`, `/dev`

### 8.3 OverlayFS In-Depth Mechanics

OverlayFS is the core technology enabling the "看起来可写，实际上共享" illusion.

**Layer Architecture**:
```text
┌─────────────────────────────────────────────────┐
│              MergedDir (Tenant View)            │  <- /
├─────────────────────────────────────────────────┤
│   UpperDir (Tmpfs, Private, Read-Write)         │  <- Tenant writes here
├─────────────────────────────────────────────────┤
│   LowerDir[0]: Link Farm (Package Dependencies) │  <- Hard links to pool
├─────────────────────────────────────────────────┤
│   LowerDir[1]: Base OS (Alpine/Debian)          │  <- Read-only base
└─────────────────────────────────────────────────┘
```

**Key Mechanisms**:

| Operation | OverlayFS Behavior | Physical Action |
|-----------|-------------------|-----------------|
| **Read** | Top-down search | Upper → Lower[0] → Lower[1] |
| **Write (new file)** | Direct write | Written to UpperDir only |
| **Modify (existing)** | Copy-Up | File copied from Lower to Upper, then modified |
| **Delete** | Whiteout | Creates special whiteout file in Upper, hides Lower file |

**Copy-Up Trigger**: When tenant executes `echo "x" >> /etc/hosts`:
1. OverlayFS detects `/etc/hosts` exists in LowerDir
2. Creates copy in UpperDir
3. Appends modification to the copy
4. Future reads see the UpperDir version

### 8.4 Process-Level View Isolation (FUSE Mode)

When running VeloVFS as FUSE without full containers, isolation uses PID-based context:

```rust
struct SessionTable {
    // Maps process tree to their virtual root
    sessions: DashMap<Pid, VeloSession>,
}

struct VeloSession {
    root_tree_hash: Blake3Hash,   // Virtual filesystem root
    tenant_id: TenantId,
    dirty_files: HashSet<PathBuf>, // Tracked modifications
}
```

**FUSE Request Handling**:
```python
def fuse_lookup(req, parent_ino, name):
    pid = req.context.pid
    session = session_table.get_session_for_pid(pid)
    
    # Same path, different content based on caller
    tree = session.root_tree_hash
    return resolve_path(tree, parent_ino, name)
```

---

## 9. VeloVFS Runtime Architecture

### 9.1 LD_PRELOAD Shim Layer

For maximum performance without FUSE overhead, Velo uses syscall interception:

```text
[ User Code (Python) ]
       |  open("/app/main.py")
       v
[ libvelo_fs.so (LD_PRELOAD) ] <--- Intercepts open(), stat(), read()
       |
       | 1. Check Manifest: "/app/main.py" == Hash(0xDEADBEEF)
       | 2. Redirect: open("/dev/shm/cas/0xDEADBEEF", O_RDONLY)
       v
[ Linux Kernel ]
       |
       v
[ Physical RAM (CAS Store) ]  <--- Zero-copy mmap
```

**Intercepted Syscalls**:
*   `open()`, `openat()` — Path resolution & redirection
*   `stat()`, `lstat()`, `fstat()` — Metadata from Manifest
*   `readlink()` — Synthetic symlink resolution
*   `readdir()` — Virtual directory listing from Tree

### 9.2 The Manifest Data Structure

Manifest provides "路径 → Hash" mapping with two layers:

**A. Base Layer (Immutable, Shared)**
*   Contains: System libraries, common packages
*   Storage: Perfect Hash Map (PHF) or FST
*   Properties: Zero-copy mmap, O(1) lookup

**B. Delta Layer (Mutable, Per-Tenant)**
*   Contains: Tenant modifications, new files, deletions
*   Storage: High-performance HashMap (SwissTable)
*   Properties: Copy-on-Write semantics

```rust
struct ManifestLookup {
    base: MmapedPHF<PathHash, VnodeEntry>,   // Global, shared
    delta: DashMap<PathHash, DeltaEntry>,    // Per-tenant
}

enum DeltaEntry {
    Modified(VnodeEntry),   // Points to new hash
    Deleted,                // Whiteout marker
}
```

### 9.3 Vnode Entry Structure

Each file/directory in Manifest is represented by a compact Vnode:

```rust
#[repr(C, packed)]
struct VnodeEntry {
    // Content addressing (32 bytes)
    content_hash: [u8; 32],  // BLAKE3 Hash
    
    // Hot metadata for stat() acceleration (24 bytes)
    size: u64,               // File size
    mtime: u64,              // Modification time (Unix epoch)
    mode: u32,               // Permission bits (rwxr-xr-x)
    flags: u16,              // IsDir, IsSymlink, IsExecutable
    _pad: u16,
}
// Total: 56 bytes per entry
// 1M files = ~56 MB memory
```

### 9.4 Lookup Flow Algorithm

```python
def vfs_open(path: str, mode: int) -> FileDescriptor:
    path_hash = blake3(path.encode())
    
    # 1. Check Delta Layer (tenant modifications)
    if (entry := delta.get(path_hash)):
        if entry == Deleted:
            raise FileNotFoundError(ENOENT)
        return open_from_cas(entry.content_hash, mode)
    
    # 2. Check Base Layer (shared packages)
    if (entry := base.get(path_hash)):
        if mode & O_WRONLY:
            # Trigger Copy-on-Write
            new_hash = copy_to_private_area(entry.content_hash)
            delta.insert(path_hash, Modified(new_hash))
            return open_from_cas(new_hash, mode)
        return open_from_cas(entry.content_hash, O_RDONLY)
    
    # 3. Not found
    raise FileNotFoundError(ENOENT)
```

### 9.5 Directory Tree Handling Strategies

**Strategy A: Flat Map + Prefix Scan (Runtime Optimized)**
*   `readdir()` scans all paths with matching prefix
*   Pros: `open()` extremely fast (most common operation)
*   Cons: `ls -R` slower on large directories

**Strategy B: Merkle DAG (Git-like, Integrity Optimized)**
*   Directories are CAS objects containing child hashes
*   Pros: Fast `readdir()`, cryptographic verification
*   Cons: Write amplification (modify one file → rehash parent chain)

**Recommendation**: Strategy A for Python runtime (import-heavy, ls-rare).

---

## 10. Python-Specific Optimizations

### 10.1 PEP 683: Immortal Objects

PEP 683 enables truly read-only shared memory for Python objects:

```python
# Standard Python: Reference counting on every access
obj = shared_numpy_array  # Py_INCREF() 写入内存 → Cache失效

# PEP 683 Mode: Immortal objects skip refcount
# Reference count locked at special value, never modified
```

**Velo Integration**:
*   Pre-loaded modules marked as immortal during Warehouse construction
*   Shared across processes without refcount traffic
*   Requires Python 3.12+

### 10.2 Import Hook Mechanism

Velo injects into Python's import machinery:

```python
# /opt/velo/lib/velo_import_hook.py
import sys
from importlib.abc import MetaPathFinder, Loader

class VeloImportFinder(MetaPathFinder):
    def find_spec(self, fullname, path, target=None):
        # Query VeloVFS for module location
        manifest_entry = velo_vfs.lookup_module(fullname)
        if manifest_entry:
            return ModuleSpec(
                fullname,
                VeloLoader(manifest_entry.cas_hash),
                origin=manifest_entry.virtual_path
            )
        return None

# Injected via PYTHONPATH or sitecustomize.py
sys.meta_path.insert(0, VeloImportFinder())
```

### 10.3 Bytecode (.pyc) Caching

Velo pre-compiles and caches bytecode in the CAS:

```json
// CAS Entry for "numpy/__init__.py"
{
  "source_hash": "blake3:abc123...",
  "variants": {
    "cpython-311": "blake3:bytecode_def456...",
    "cpython-312": "blake3:bytecode_ghi789..."
  }
}
```

**Runtime Flow**:
1. Import requests `numpy/__init__.py`
2. Velo checks for cached bytecode matching current Python version
3. If hit: Return bytecode blob directly to interpreter
4. If miss: Compile, cache for next time

---

## 11. uv Deep Integration

### 11.1 Resolution-Only Mode

Velo leverages uv's resolver without performing actual installation:

```bash
# Traditional uv: Download + Extract + Install
uv pip install numpy pandas

# Velo-uv: Resolve Only → Query CAS → Instant Link
uv pip compile requirements.txt --universal -o deps.lock
velo ingest deps.lock  # Check CAS, download missing only
```

### 11.2 Virtual Installation Flow

```python
def handle_pip_install(packages: List[str]):
    # 1. Resolve (no network I/O if cached)
    lock_plan = uv_resolve_only(packages)
    
    # 2. Check Global CAS
    install_plan = {}
    missing = []
    for pkg in lock_plan:
        cas_key = f"{pkg.name}-{pkg.version}-{platform}"
        if (hash := global_cas.get(cas_key)):
            install_plan[pkg.name] = hash
        else:
            missing.append(pkg)
    
    # 3. Backfill missing packages
    if missing:
        staged = uv_install_to_staging(missing)
        for pkg, files in staged:
            tree_hash = ingest_to_cas(files)
            install_plan[pkg] = tree_hash
    
    # 4. Instant Install (pointer update only)
    tenant_manifest.update(install_plan)
    print(f"Installed {len(lock_plan)} packages in 0ms")
```

### 11.3 Metadata Deception

Making `pip list` and other tools see installed packages:

```text
/site-packages/
├── numpy/                    <- Mapped from CAS
├── numpy-1.26.0.dist-info/   <- Also mapped from CAS
│   ├── METADATA              <- Version: 1.26.0
│   ├── RECORD                <- File checksums
│   └── INSTALLER             <- "velo"
```

Standard tools scan `.dist-info` directories — Velo ensures they exist in the virtual view.

---

## 12. Performance Optimizations

### 12.1 Packfile / Blob Packing (Hotspot Consolidation)

Small files (node_modules, .pyc) cause random I/O. Velo packs related files together:

**Profile-Guided Packing**:
```python
# Trace: Record access order during startup
startup_trace = [
    ("hash_A", 0ms),   # index.js
    ("hash_B", 2ms),   # utils.js  
    ("hash_C", 5ms),   # config.js
]

# Pack: Write frequently co-accessed files contiguously
packfile = create_packfile([hash_A, hash_B, hash_C])
# Physical layout: [ContentA][ContentB][ContentC]

# Benefit: OS readahead loads all 3 with single I/O
```

**Index Update**:
```json
// Before: Hash → Loose Blob
{ "hash_A": { "type": "blob", "path": "/cas/a1/b2..." } }

// After: Hash → Packfile Offset
{ "hash_A": { "type": "packed", "pack": "pack_001", "offset": 0, "len": 1024 } }
```

### 12.2 V8 Bytecode Caching (Node.js)

For Node.js acceleration, Velo caches compiled V8 bytecode:

**Injection via NODE_OPTIONS**:
```bash
export NODE_OPTIONS="--require /opt/velo/lib/accelerator.js"
```

**Accelerator Logic**:
```javascript
const Module = require('module');
const v8 = require('v8');

Module._extensions['.js'] = function(module, filename) {
    const sourceHash = getVeloHash(filename);
    const v8Version = process.versions.v8;
    
    // Shadow path for cached bytecode
    const cachePath = `/.velo/cache/${sourceHash}/${v8Version}.bin`;
    
    if (fs.existsSync(cachePath)) {
        const cachedData = fs.readFileSync(cachePath);
        const script = new vm.Script(source, { cachedData });
        // V8 skips parsing, directly deserializes bytecode
        return script.runInThisContext();
    }
    
    // Fallback: compile and cache for next time
    const compiled = compileAndCache(filename, cachePath);
    return compiled;
};
```

### 12.3 velod Daemon Architecture

The Velo daemon (`velod`) manages background tasks:

```text
┌──────────────────────────────────────┐
│               velod                  │
├──────────────────────────────────────┤
│  ┌────────────┐  ┌────────────────┐  │
│  │ CAS Manager│  │ Session Tracker│  │
│  └────────────┘  └────────────────┘  │
│  ┌────────────┐  ┌────────────────┐  │
│  │ Pack Daemon│  │ Prefetch Worker│  │
│  └────────────┘  └────────────────┘  │
│  ┌─────────────────────────────────┐ │
│  │          LMDB Store             │ │
│  └─────────────────────────────────┘ │
└──────────────────────────────────────┘
```

**Components**:
*   **CAS Manager**: Hash → Location resolution
*   **Session Tracker**: PID → Manifest mapping
*   **Pack Daemon**: Background hotspot consolidation
*   **Prefetch Worker**: Predictive blob loading

---

## 13. Hash & ID Optimization Strategy

### 13.1 Storage vs Runtime Hash Sizes

| Layer | Hash Size | Rationale |
|-------|-----------|-----------|
| **Disk/Network** | 256-bit BLAKE3 | Cryptographic safety, global uniqueness |
| **Memory/Runtime** | 32-bit Local ID | Cache efficiency, CPU optimization |
| **CLI/Display** | Hex prefix (8+ chars) | Human readability |

### 13.2 Interning Pattern

Convert large hashes to compact sequential IDs:

```rust
struct HashRegistry {
    // Full Hash → Local ID
    hash_to_id: HashMap<Blake3Hash, u32>,
    // Local ID → Full Hash (array index = ID)
    id_to_hash: Vec<Blake3Hash>,
}

impl HashRegistry {
    fn intern(&mut self, hash: Blake3Hash) -> u32 {
        if let Some(&id) = self.hash_to_id.get(&hash) {
            return id;  // Already seen
        }
        let id = self.id_to_hash.len() as u32;
        self.id_to_hash.push(hash);
        self.hash_to_id.insert(hash, id);
        id  // New sequential ID
    }
}
```

**Benefits**:
*   Array access `O(1)` vs HashMap lookup
*   `u32` fits in single cache line with neighbors
*   32-bit comparison = single CPU instruction

### 13.3 Bit-Packed IDs (48-bit ID + 16-bit Flags)

Optimal memory layout using bit packing:

```rust
#[derive(Clone, Copy)]
pub struct VeloId(u64);

impl VeloId {
    const ID_MASK: u64   = 0x0000_FFFF_FFFF_FFFF;  // Low 48 bits
    const FLAG_MASK: u64 = 0xFFFF_0000_0000_0000;  // High 16 bits
    
    pub fn new(index: u64, flags: u16) -> Self {
        VeloId((index & Self::ID_MASK) | ((flags as u64) << 48))
    }
    
    #[inline(always)]
    pub fn index(&self) -> usize {
        (self.0 & Self::ID_MASK) as usize
    }
    
    #[inline(always)]
    pub fn is_dir(&self) -> bool {
        (self.0 & (1 << 63)) != 0
    }
}
```

**48-bit capacity**: 281 trillion IDs — physically impossible to exhaust (memory would OOM first).

---

## 14. Cross-Language Ecosystem Support

### 14.1 Protocol Adapter Architecture

VeloVFS is language-agnostic. Language-specific logic lives in adapters:

```text
┌─────────────────────────────────────────────────┐
│                 Application Layer               │
│  Node.js    Python    Rust/Cargo    Go         │
└────────┬────────┬────────┬────────┬────────────┘
         │        │        │        │
         v        v        v        v
┌─────────────────────────────────────────────────┐
│              Protocol Adapters                  │
│  npm-adapter  uv-adapter  cargo-adapter  go-mod│
└────────────────────┬────────────────────────────┘
                     │
                     v
┌─────────────────────────────────────────────────┐
│               VeloVFS Core                      │
│    CAS Storage  |  Git Trees  |  Mounting      │
└─────────────────────────────────────────────────┘
```

### 14.2 Cargo/Rust Acceleration

**Problem**: Path-based fingerprinting causes rebuild across projects.

**Velo Solution**: Path Illusion
```bash
# All projects see same virtual path
/app/workspace/  ← Project A code
/app/workspace/  ← Project B code (different physical location)

# Cargo computes identical fingerprints → cache hit
RUSTFLAGS="--remap-path-prefix $(pwd)=/app/workspace" cargo build
```

**Result**: Global compilation cache across all Rust projects.

### 14.3 NPM/Node.js node_modules Deduplication

**Problem**: `node_modules` black hole (100k+ files, GB of duplicates).

**Velo Solution**: Virtual node_modules
```json
// Manifest generates virtual tree
{
  "/node_modules/react/index.js": "hash_A",
  "/node_modules/lodash/lodash.js": "hash_B",
  "/node_modules/foo/node_modules/lodash/lodash.js": "hash_B"  // Same hash!
}
```

*   1000 packages → 1000 entries in manifest (not files)
*   Physical storage: Only unique content
*   `npm install` time: O(1) pointer updates

---

## 15. Cluster / Distributed Mode

### 15.1 Tiered Caching Architecture

```text
┌─────────────────────────────────────────────────────────┐
│ L1: Host Memory/NVMe                                    │
│     Latency: <1ms | Capacity: 10-100GB | Shared: Local  │
├─────────────────────────────────────────────────────────┤
│ L2: Datacenter Cache (Redis/Memcached)                  │
│     Latency: 1-5ms | Capacity: TB | Shared: Region      │
├─────────────────────────────────────────────────────────┤
│ L3: P2P Mesh (BitTorrent-style)                        │
│     Latency: 10-50ms | Capacity: ∞ | Shared: Cluster   │
├─────────────────────────────────────────────────────────┤
│ L4: Origin (S3/MinIO)                                   │
│     Latency: 50-200ms | Capacity: ∞ | Shared: Global   │
└─────────────────────────────────────────────────────────┘
```

### 15.2 Lazy Loading Protocol

Container starts before all data is downloaded:

```python
def lazy_start_container(manifest_hash):
    # 1. Download only metadata (KB)
    tree = fetch_tree(manifest_hash)  # ~10KB
    
    # 2. Mount immediately (VFS virtual view)
    vfs.mount(tree, "/app")
    
    # 3. Start process
    proc = spawn("/app/main.py")
    
    # 4. On page fault: fetch blob on-demand
    # VFS intercepts read() → triggers L1→L2→L3→L4 lookup
```

**Cold Start Time**: From minutes (full pull) → seconds (metadata only).

### 15.3 P2P Cache Sharing

When 1000 nodes need the same model weights:

```text
Traditional: 1000 × S3 download = $$$, bandwidth bottleneck

Velo P2P:
  - Node 1 downloads from S3
  - Node 2-1000 discover Node 1 has the blob
  - Parallel transfer within datacenter (free, 100Gbps)
```

**Discovery Protocol**: Gossip-based hash announcement.

---

## 16. Persistence & Recovery

### 16.1 LMDB Memory-Mapped Store

Why LMDB for Git metadata:
*   **mmap-based**: Data stays in kernel page cache
*   **Zero-copy reads**: No deserialization
*   **Instant restart**: Open file = ready to serve
*   **ACID transactions**: Crash-safe via CoW B-tree

```rust
// Restart time comparison
// SQLite: Load → Parse → Index Build → Ready (seconds)
// LMDB:   mmap() → Ready (milliseconds)
```

### 16.2 Turbo Configuration

For maximum performance with acceptable durability trade-offs:

```c
// Velo LMDB Config
mdb_env_set_flags(env, MDB_WRITEMAP);   // Direct memory writes
mdb_env_set_flags(env, MDB_NOSYNC);     // Async flush (~30s by OS)
mdb_env_set_flags(env, MDB_MAPASYNC);   // Non-blocking dirty page write
```

**Worst case**: Crash loses last 30 seconds of `pip install` — easily recoverable from `uv.lock`.

### 16.3 Rebuild from Source of Truth

LMDB is derived data. If lost, rebuild from:
1. **uv.lock / package-lock.json** — Intent (what packages)
2. **CAS Blobs** — Content (the actual files)

```python
def rebuild_metadata():
    lmdb = create_empty_lmdb()
    
    for tenant in discover_tenants():
        lockfile = read_lockfile(tenant.uv_lock_path)
        
        for package in lockfile.packages:
            tree_hash = build_tree_from_cas(package)
            lmdb.insert(f"refs/tenants/{tenant.id}/HEAD", tree_hash)
    
    print("Recovery complete")
```

**Recovery time**: Proportional to number of tenants, not data size.

---

## 17. Comparison with Existing Systems

### 17.1 VeloVFS vs Traditional Cluster Filesystems

| Feature | Ceph/GlusterFS | NFS | VeloVFS |
|---------|---------------|-----|---------|
| **Primary Goal** | Store data reliably | Share files | Accelerate code execution |
| **Deduplication** | Block-level (expensive) | None | Content-addressable (free) |
| **Mutable Data** | First-class | First-class | CoW overlay, immutable base |
| **Cold Start** | Full download | Remote mount | Lazy page fault |
| **Best For** | Large files, databases | General sharing | Package management, CI/CD |

### 17.2 VeloVFS vs Package Managers

| Feature | npm/pip | pnpm | Velo |
|---------|---------|------|------|
| **Dedup Scope** | None | Per-machine | Global/Cloud |
| **Install Mechanism** | File copy | Hard links | VFS pointers |
| **Cross-Project Share** | No | Yes | Yes + Memory |
| **Cold Start Overhead** | High | Medium | Near-zero |

### 17.3 Bun vs Node+Velo

| Dimension | Bun | Node.js + Velo |
|-----------|-----|----------------|
| **I/O Performance** | io_uring | mmap (no I/O) |
| **Install Speed** | Fast (hardlinks) | Instant (manifest) |
| **Ecosystem Compat** | ~95% | 100% |
| **Migration Cost** | High (new runtime) | Zero (same Node) |
| **Disk Usage** | Per-project cache | Global CAS |
