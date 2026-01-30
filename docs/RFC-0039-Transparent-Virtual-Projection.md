# RFC-0039: Transparent Virtual Projection & In-place Transmutation

## 1. Status
**Draft**

## 2. Context & Objectives
Velo Rift™ aims to eliminate the friction between "Project Content" and "Disk Storage." This RFC proposes a **Transparent Projection Model** where the VFS layer replaces heavy-duty physical directories (e.g., `node_modules`, `target`, `.venv`) with a dynamic virtual lens. The environment is intended to be **long-lived**, becoming the primary state of the workspace rather than a transient execution context.

## 3. Core Concepts

### 3.1 Active Projection
- **Action**: `vrift active`
- **Function**: Transitions the workspace into a persistent **Projected State**. Velo Rift™ acts as a "Live Lens" over the project directory.
- **Dependency Replacement**: Folders like `node_modules` or `target` are projected from the CAS. They appear physically present but are managed virtual assets.

### 3.2 Live Ingest (Automated `ingest`)
Velo Rift™ automates the existing `ingest` logic:
- **Trigger**: When a process finishes writing a file (`close()`), Velo performs a **Live Ingest**.
- **Efficiency**: The file is hashed and either moved or hardlinked into the CAS (matching the standard `ingest` behavior).
- **SSOT**: The Manifest is updated immediately, ensuring the virtual view is always in sync with new writes.

### 3.3 Dimensional Ingest (ABI Tags)
To handle multi-version binaries:
- The `ingest` process considers the **ABI_Context** for binary files (`.so`, `.dylib`).
- This prevents collisions between different versions (e.g., Python 3.10 vs 3.11) at the same path.

## 4. Implementation Notes
- **Persistent State**: `vrift active` creates a long-lived Session, maintaining the projection until explicit deactivation.
- **Consistency**: Uses `mtime` as a guard. If a physical file is modified externally, the system reflects the change and re-triggers `ingest` as needed.
- **Shim Performance**: Capture occurs on `close()`, ensuring native disk speed during the write cycle.
