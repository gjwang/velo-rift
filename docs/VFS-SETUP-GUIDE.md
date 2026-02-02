# Velo Rift VFS Setup Guide

## Quick Start

```bash
# 1. Initialize project
cd my-project
vrift init

# 2. Ingest dependencies (first time)
vrift ingest node_modules

# 3. Enter Inception Mode
eval "$(vrift inception)"

# 4. Work normally - all I/O goes through VFS
npm run build

# 5. Exit when done
eval "$(vrift wake)"
```

---

## User Experience Flow

### First Time Setup

```
$ vrift init
╭───────────────────────────────────────╮
│ 🌀 Velo Rift Initialized              │
│                                       │
│ Created: .vrift/                      │
│          ├── manifest.lmdb            │
│          └── bin/ (wrappers)          │
│                                       │
│ Next: vrift ingest <dir>              │
╰───────────────────────────────────────╯
```

### Entering Inception

```
$ eval "$(vrift inception)"
🌀 INCEPTION: Entering the dream...
   ✔ Daemon connected (1,234 files cached)
   ✔ VFS layer active
   ✔ PATH wrappers installed
   ✔ Reality distorted. Happy hacking.

(vrift 🌀) $
```

### Auto-Inception (Shell Hook)

```bash
# Add to ~/.zshrc
eval "$(vrift hook zsh)"

# Now auto-activates:
$ cd my-project/
🌀 Auto-entering dream layer...
(vrift 🌀) $

$ cd ../
💫 Auto-waking...
$
```

---

## Architecture

### Daemon (vriftd)

**Role:** Singleton background process for all VFS operations.

| Aspect | Design |
|--------|--------|
| Lifecycle | Starts on first `vrift inception`, stays running |
| Supervisor | macOS: launchd `KeepAlive`, Linux: systemd `Restart=always` |
| Socket | `/tmp/vrift.sock` (Unix domain socket) |
| State | Hot stat cache, manifest mmap, CAS index |

**Auto-start:** If daemon not running when entering inception:
```
(vrift 🌀) $ # daemon auto-starts
Starting vriftd... ✓
```

### DYLD Shim

**Role:** Intercepts file I/O syscalls at process level.

Works for:
- ✅ Python scripts (`os.chmod()`)
- ✅ Node programs (`fs.chmod()`)
- ✅ Compiled user binaries

Does NOT work for (SIP protected):
- ❌ `/bin/chmod`, `/bin/rm`, `/bin/cp`
- ❌ `/usr/bin/*`

### PATH Wrappers (SIP Bypass)

**RFC-0048 Solution:** Shell wrapper scripts in `.vrift/bin/`

```
.vrift/
├── bin/
│   ├── chmod      ← wrapper script (not binary copy!)
│   ├── rm         ← wrapper script
│   └── cp         ← wrapper script
├── helpers/
│   ├── vrift-chmod  ← shim-loadable binary
│   └── ...
└── manifest.lmdb
```

**Wrapper Logic:**
```bash
#!/bin/bash
# .vrift/bin/chmod - Inception-aware wrapper

TARGET="${@: -1}"
[[ "$TARGET" != /* ]] && TARGET="$(pwd)/$TARGET"

if [[ "$TARGET" == "$VRIFT_PROJECT_ROOT"* ]]; then
    # VFS path: use shim-loadable helper
    exec "$VRIFT_PROJECT_ROOT/.vrift/helpers/vrift-chmod" "$@"
else
    # Non-VFS path: passthrough to system binary
    exec /bin/chmod "$@"
fi
```

**Key Insight:** We don't copy `/bin/chmod` (blocked by SIP). We create a tiny shell wrapper that decides at runtime which binary to call.

---

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `VRIFT_INCEPTION=1` | Signals inception mode active |
| `VRIFT_PROJECT_ROOT` | Project directory path |
| `VRIFT_MANIFEST` | Path to `.vrift/manifest.lmdb` |
| `VRIFT_VFS_PREFIX` | VFS path prefix for shim |
| `PATH=".vrift/bin:$PATH"` | Wrappers override system bins |
| `DYLD_INSERT_LIBRARIES` | Shim injection for user binaries |

---

## Error Handling

### Daemon Not Running

```
$ eval "$(vrift inception)"
⚠️  Daemon not running, starting...
   Starting vriftd... ✓
🌀 INCEPTION active
```

### Daemon Failed

```
$ eval "$(vrift inception)"
❌ Daemon failed to start

Diagnostics:
  • Socket: /tmp/vrift.sock (missing)
  • Log: ~/.vrift/logs/daemon.log

Suggested:
  1. vrift doctor     # Auto-diagnose
  2. vrift daemon log # View logs
```

### Not Initialized

```
$ eval "$(vrift inception)"
❌ Not a Velo Rift project

Run: vrift init
```

---

## Comparison with Similar Tools

| Tool | Activation | Mechanism |
|------|------------|-----------|
| **Velo Rift** | `eval "$(vrift inception)"` | PATH + DYLD shim |
| pyenv | `eval "$(pyenv init)"` | PATH shims |
| rustup | implicit | PATH proxy |
| mise | `eval "$(mise activate)"` | PATH shims |
| direnv | `eval "$(direnv hook)"` | env auto-switch |
| Docker | `docker-compose up` | Container |

Velo Rift follows the **same pattern** as pyenv/rustup - explicit activation, user-space PATH modification, no system changes.
