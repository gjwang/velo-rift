# Velo Rift™: Comprehensive Usage Guide

Velo Rift is a high-performance **data virtualization layer** designed for the AI-native era. It decouples "where a file lives" from "what a file contains," allowing you to run applications in virtualized environments with zero overhead.

---

## 🚀 Quick Start (Zero-Config)

The fastest way to experience Velo Rift™ is to just run your code. No manual ingestion or manifest setup required.

In any project directory (Python, Node.js, or Rust):
```bash
# Just run your command. Velo Rift™ will auto-detect your project.
vrift run -- python3 main.py
```
Velo Rift™ will perform a **Transient Ingest** on the fly, creating a temporary virtual view of your project and executing it immediately.

---

## 🛠 Step 1: Project Initialization

For professional projects, you may want a persistent configuration with custom filters (e.g., ignoring `node_modules` or `target/`).

```bash
# Run in your project root
vrift init
```
*   **What it does**: Detects your project type (Cargo, npm, Pip) and creates a `vrift.manifest`.
*   **Why use it**: It applies smart **LifeCode™ filters** to ensure only source code is virtualized, keeping your environment lean.

---

## 🏃 Step 2: Virtual Execution

Once you have a manifest (or even if you don't), use `vrift run` to execute code inside the **VeloVFS** layer.

### Basic Run
```bash
vrift run -- <command>
```

### Manual Manifest Selection
If you have multiple manifests (e.g., for different environment versions):
```bash
vrift run --manifest environments/stable.manifest -- ./deploy.sh
```

---

## 🛡 Step 3: Advanced Isolation (Linux Only)

For multi-tenant environments or security-critical tasks, Velo Rift™ supports **Rootless Isolation** using Linux Namespaces.

### Isolated Sandbox
```bash
vrift run --isolate -- python3 malicious_script.py
```

### Layered Manifests (Base Images)
You can stack manifests to create a layered environment (similar to Docker layers but without the performance penalty):
```bash
# Run app.manifest on top of a static busybox toolchain
vrift run --isolate --base busybox.manifest --manifest app.manifest -- /bin/sh
```

---

## 📊 Step 4: Maintenance & Optimization

### Monitor Savings
Velo Rift™ provides global deduplication. See how much disk space you're saving across all projects:
```bash
vrift status
```

### Garbage Collection
Cleanup blobs that are no longer referenced by any manifest:
```bash
# Perform a dry run first
vrift gc
# Actually delete orphaned data
vrift gc --delete
```

---

## 🧠 Under the Hood: Principles

### 1. Hash(Content) = Identity
In Velo, identity is tied to **Content**, not path. If 100 projects use the same `libpython.so`, Velo Rift stores only **one** copy in **TheSource** (CAS).

### 2. Two Projection Modes
Velo Rift chooses the best way to "project" the virtual world based on your OS:
*   **The Shim (macOS/Linux)**: Uses `LD_PRELOAD` to intercept syscalls. Zero disk footprint. Best for local development.
*   **Link Farm (Linux Isolation)**: Creates a temporary directory of hardlinks. Best for containers and static binaries.

### 3. Absolute Determinism
A `vrift.manifest` uniquely defines an entire environment. If the manifest hash is the same, the execution outcome is guaranteed to be reproducible.
