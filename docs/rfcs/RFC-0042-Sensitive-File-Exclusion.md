# RFC-0042: Sensitive File Auto-Exclusion (Security Guard)

| Status | Author | Created |
|--------|--------|---------|
| Draft  | VRift Team | 2026-01-31 |

---

## Summary

VRift ingest should **automatically exclude sensitive files** by default to prevent accidental exposure of secrets, credentials, and private keys in the shared CAS. This RFC defines the default exclusion patterns and provides configuration options for users who need to override this behavior.

---

## Motivation

### Problem

Currently, `vrift ingest` processes ALL files in the target directory without filtering. This creates security risks:

1. **Credentials Exposure**: `.env`, `.aws/credentials`, API keys leak into CAS
2. **Private Key Exposure**: SSH keys, TLS certificates stored in plaintext blobs
3. **Data Leakage**: Database dumps, user data in shared storage
4. **Compliance Risk**: PII/GDPR-sensitive data in unencrypted storage

### Real-World Scenario

```bash
# Developer runs this innocently
vrift ingest ./my-project -o manifest.bin

# But ./my-project contains:
#   .env                    → AWS_SECRET_KEY, DB_PASSWORD
#   config/secrets.yaml     → production API tokens
#   certs/server.key        → TLS private key
#   .ssh/id_rsa            → SSH private key (if symlinked)
```

All these files are now stored in `~/.vrift/the_source/` with **no encryption**.

### Non-Goal: Respecting .gitignore

> **Important**: This RFC is NOT about respecting `.gitignore`.

VRift's purpose is to cache **build artifacts** (node_modules, target/, etc.) which are typically IN `.gitignore`. We want to ingest those. We only want to exclude **security-sensitive** files.

---

## Design

### Default Exclusion Categories

#### Category 1: Environment & Secrets (HIGH RISK)

| Pattern | Description |
|---------|-------------|
| `.env*` | Environment variables (`.env`, `.env.local`, `.env.production`) |
| `*.secret` | Generic secret files |
| `secrets.yaml`, `secrets.json` | Secret configuration |
| `.secrets/` | Secret directories |

#### Category 2: Credentials (HIGH RISK)

| Pattern | Description |
|---------|-------------|
| `.aws/credentials` | AWS credentials |
| `.aws/config` | AWS config (may contain keys) |
| `.docker/config.json` | Docker registry auth |
| `.npmrc` | npm auth tokens |
| `.netrc` | FTP/HTTP credentials |
| `.git-credentials` | Git credential cache |
| `.pypirc` | PyPI credentials |

#### Category 3: Private Keys (CRITICAL)

| Pattern | Description |
|---------|-------------|
| `*.pem` | PEM certificates/keys |
| `*.key` | Private key files |
| `*.p12`, `*.pfx` | PKCS#12 bundles |
| `id_rsa*`, `id_ed25519*`, `id_ecdsa*` | SSH private keys |
| `*.ppk` | PuTTY private keys |

#### Category 4: VRift Internal

| Pattern | Description |
|---------|-------------|
| `.vrift/` | VRift cache directories |
| `.git/` | Git internals (not security, but wasteful) |

### CLI Interface

```bash
# Default: excludes sensitive files automatically
vrift ingest ./node_modules -o manifest.bin

# Show what would be excluded (dry-run style)
vrift ingest ./node_modules --show-excluded

# Override: include ALL files (dangerous, requires explicit flag)
vrift ingest ./project --no-security-filter

# Custom exclusion patterns (additive to defaults)
vrift ingest ./project --exclude "*.log" --exclude "cache/"

# Custom inclusion (whitelist a normally-excluded pattern)
vrift ingest ./project --include ".env.example"
```

### Output UX

> **Principle: No Silent Operations**
>
> VRift should always clearly echo what it's doing: storage location, mode, security status, and results. Users should never be surprised by where data went.

#### Normal Operation (Security Filter Active)

```
⚡ VRift Ingest
   Mode:    Solid Tier-2 (hard_link, keep original)
   CAS:     ~/.vrift/the_source
   Threads: 4
   🛡️  Security: Filter ACTIVE (3 files excluded)

   [progress bar...]

╔════════════════════════════════════════╗
║  ✅ VRift Complete in 2.34s           ║
╚════════════════════════════════════════╝

   📁 16,644 files → 13,780 blobs
   🛡️  3 sensitive files excluded:
       .env, config/secrets.yaml, certs/server.key
   ...
```

#### Security Filter Disabled (Warning Every Time)

```
⚡ VRift Ingest
   Mode:    Solid Tier-2 (hard_link, keep original)
   CAS:     ~/.vrift/the_source
   Threads: 4

   ⚠️  SECURITY FILTER DISABLED (--no-security-filter)
   ⚠️  Sensitive files (.env, *.key, etc.) WILL be ingested!

   [progress bar...]

╔════════════════════════════════════════╗
║  ⚠️  VRift Complete (UNFILTERED)      ║
╚════════════════════════════════════════╝

   📁 16,647 files → 13,783 blobs
   ⚠️  Security filter was disabled - review ingested files
   ...
```

#### Verbose Mode (--show-excluded)

```
⚡ VRift Ingest
   Mode:    Solid Tier-2 (hard_link, keep original)
   CAS:     ~/.vrift/the_source
   Threads: 4
   🛡️  Security: Filter ACTIVE

   🛡️  Excluded files (5):
       .env                      (environment secrets)
       .env.local                (environment secrets)
       config/secrets.yaml       (secrets file)
       certs/server.key          (private key)
       .aws/credentials          (credentials)

   [continue with ingest...]
```

### Configuration File (Optional)

Users can create `~/.vrift/security.toml` for persistent configuration:

```toml
[security]
# Add custom exclusions
exclude = [
    "*.sql",
    "dumps/",
    "company-secrets/**"
]

# Whitelist patterns (override defaults)
include = [
    ".env.example",
    "*.pem.pub"  # Public keys are safe
]

# Disable security filter globally (NOT RECOMMENDED)
# disable = true
```

---

## Implementation

### Phase 1: Core Implementation

1. Create `SecurityFilter` struct with default patterns
2. Integrate into `WalkDir` traversal
3. Track and report excluded files
4. Add `--no-security-filter` flag

### Phase 2: CLI Enhancement

1. Add `--show-excluded` flag
2. Add `--exclude` and `--include` flags
3. Add warning when `--no-security-filter` used

### Phase 3: Configuration

1. Parse `~/.vrift/security.toml`
2. Merge with CLI flags
3. Add `vrift config security` subcommand

---

## Pattern Matching

Use `globset` crate for efficient pattern matching:

```rust
use globset::{Glob, GlobSet, GlobSetBuilder};

struct SecurityFilter {
    exclude: GlobSet,
    include: GlobSet,
}

impl SecurityFilter {
    fn should_exclude(&self, path: &Path) -> bool {
        self.exclude.is_match(path) && !self.include.is_match(path)
    }
}
```

---

## Default Patterns (Complete List)

```rust
const DEFAULT_EXCLUDE_PATTERNS: &[&str] = &[
    // Environment & Secrets
    ".env",
    ".env.*",
    "*.secret",
    "secrets.yaml",
    "secrets.json",
    "secrets.toml",
    ".secrets/**",
    
    // Credentials
    ".aws/credentials",
    ".aws/config",
    ".docker/config.json",
    ".npmrc",
    ".netrc",
    ".git-credentials",
    ".pypirc",
    ".composer/auth.json",
    ".m2/settings.xml",
    ".gradle/gradle.properties",
    
    // Private Keys
    "*.pem",
    "*.key",
    "*.p12",
    "*.pfx",
    "*.jks",
    "id_rsa",
    "id_rsa.*",
    "id_ed25519",
    "id_ed25519.*",
    "id_ecdsa",
    "id_ecdsa.*",
    "*.ppk",
    
    // VRift Internal
    ".vrift/**",
    ".git/**",
];
```

---

## Security Considerations

1. **Defense in Depth**: This is one layer; CAS encryption is a separate concern
2. **Pattern Updates**: New patterns may be added in future versions
3. **User Override**: `--no-security-filter` requires explicit intent
4. **Audit Log**: Consider logging when sensitive files are encountered

---

## Alternatives Considered

### 1. Encrypt All Blobs
- **Pros**: Protects even if filter fails
- **Cons**: Performance overhead, key management complexity
- **Decision**: Future enhancement, not a substitute for filtering

### 2. Per-User CAS Permissions
- **Pros**: Isolation at OS level
- **Cons**: Doesn't prevent accidental self-exposure
- **Decision**: Complementary, should also be implemented

### 3. Content-Based Detection
- **Pros**: Catches secrets in arbitrary files (e.g., hardcoded in code)
- **Cons**: High complexity, false positives, performance impact
- **Decision**: Out of scope for v1

---

## Open Questions

~~1. Should we warn on `--no-security-filter` every time or only once?~~
   - **Resolved**: Warn every time. UX should be explicit, not silent.

~~2. Should exclusion count be shown in manifest/registry?~~
   - **Resolved**: No. Only show in terminal output.
   - Reason: Simplicity, security (excluded file list is itself sensitive), reproducibility (`--show-excluded` can re-scan).

---

## References

- [GitHub Secret Scanning Patterns](https://docs.github.com/en/code-security/secret-scanning)
- [gitleaks patterns](https://github.com/gitleaks/gitleaks)
- [truffleHog patterns](https://github.com/trufflesecurity/trufflehog)
