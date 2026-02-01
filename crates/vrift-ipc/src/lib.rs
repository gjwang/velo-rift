use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
pub enum VeloRequest {
    Handshake {
        client_version: String,
    },
    Status,
    Spawn {
        command: Vec<String>,
        env: Vec<(String, String)>,
        cwd: String,
    },
    CasInsert {
        hash: [u8; 32],
        size: u64,
    },
    CasGet {
        hash: [u8; 32],
    },
    Protect {
        path: String,
        immutable: bool,
        owner: Option<String>,
    },
    ManifestGet {
        path: String,
    },
    ManifestUpsert {
        path: String,
        entry: vrift_manifest::VnodeEntry,
    },
    /// List directory entries for VFS synthesis
    ManifestListDir {
        path: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DirEntry {
    pub name: String,
    pub is_dir: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub enum VeloResponse {
    HandshakeAck {
        server_version: String,
    },
    StatusAck {
        status: String,
    },
    SpawnAck {
        pid: u32,
    },
    CasAck,
    CasFound {
        size: u64,
    },
    CasNotFound,
    ManifestAck {
        entry: Option<vrift_manifest::VnodeEntry>,
    },
    /// Directory listing response for VFS synthesis
    ManifestListAck {
        entries: Vec<DirEntry>,
    },
    ProtectAck,
    Error(String),
}

/// Default daemon socket path
pub fn default_socket_path() -> &'static str {
    "/tmp/vrift.sock"
}

pub const BLOOM_SIZE: usize = 128 * 1024;

// ============================================================================
// Manifest Mmap Shared Memory (RFC-0044 Hot Stat Cache)
// ============================================================================

/// Magic number for manifest mmap file: "VMMP" (Vrift Manifest MmaP)
pub const MMAP_MAGIC: u32 = 0x504D4D56;
/// Current mmap format version
pub const MMAP_VERSION: u32 = 1;
/// Maximum entries in the hash table (power of 2 for fast modulo)
pub const MMAP_MAX_ENTRIES: usize = 65536;
/// Default mmap file path
pub const MMAP_DEFAULT_PATH: &str = "/tmp/vrift-manifest.mmap";

/// Header for the mmap'd manifest file
/// Layout: [Header][Bloom Filter][Hash Table]
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ManifestMmapHeader {
    pub magic: u32,
    pub version: u32,
    pub entry_count: u32,
    pub bloom_offset: u32,   // Offset to bloom filter
    pub table_offset: u32,   // Offset to hash table
    pub table_capacity: u32, // Number of slots in hash table
    pub _reserved: [u32; 2], // Future use
}

impl ManifestMmapHeader {
    pub const SIZE: usize = std::mem::size_of::<Self>();

    pub fn new(entry_count: u32, table_capacity: u32) -> Self {
        Self {
            magic: MMAP_MAGIC,
            version: MMAP_VERSION,
            entry_count,
            bloom_offset: Self::SIZE as u32,
            table_offset: (Self::SIZE + BLOOM_SIZE) as u32,
            table_capacity,
            _reserved: [0; 2],
        }
    }

    pub fn is_valid(&self) -> bool {
        self.magic == MMAP_MAGIC && self.version == MMAP_VERSION
    }
}

/// Single stat entry in the hash table
/// Uses open addressing with linear probing
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct MmapStatEntry {
    pub path_hash: u64, // FNV-1a hash of path (0 = empty slot)
    pub size: u64,
    pub mtime: i64,
    pub mtime_nsec: i64,
    pub mode: u32,
    pub flags: u32, // EntryFlags: is_dir, is_symlink, etc.
}

impl MmapStatEntry {
    pub const SIZE: usize = std::mem::size_of::<Self>();

    pub fn is_empty(&self) -> bool {
        self.path_hash == 0
    }

    pub fn is_dir(&self) -> bool {
        (self.flags & 0x01) != 0
    }

    pub fn is_symlink(&self) -> bool {
        (self.flags & 0x02) != 0
    }
}

/// Calculate FNV-1a hash for path strings (deterministic, no alloc)
#[inline(always)]
pub fn fnv1a_hash(s: &str) -> u64 {
    const FNV_OFFSET: u64 = 0xcbf29ce484222325;
    const FNV_PRIME: u64 = 0x100000001b3;

    let mut hash = FNV_OFFSET;
    for byte in s.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    hash
}

/// Calculate total mmap file size for given capacity
pub fn mmap_file_size(table_capacity: usize) -> usize {
    ManifestMmapHeader::SIZE + BLOOM_SIZE + (table_capacity * MmapStatEntry::SIZE)
}

pub fn bloom_hashes(s: &str) -> (usize, usize) {
    let mut h1: usize = 5381;
    let mut h2: usize = 0;
    for &b in s.as_bytes() {
        h1 = h1.wrapping_shl(5).wrapping_add(h1).wrapping_add(b as usize);
        h2 = h2
            .wrapping_shl(6)
            .wrapping_add(h2)
            .wrapping_add(b as usize)
            .wrapping_sub(h1);
    }
    (h1, h2)
}

/// Check if daemon is running (socket exists and connectable)
pub fn is_daemon_running() -> bool {
    std::path::Path::new(default_socket_path()).exists()
}

/// IPC Client for communicating with vrift-daemon
pub mod client {
    use super::*;
    use std::path::Path;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::UnixStream;

    pub struct DaemonClient {
        stream: UnixStream,
    }

    impl DaemonClient {
        /// Connect to daemon at default socket path
        pub async fn connect() -> anyhow::Result<Self> {
            Self::connect_to(default_socket_path()).await
        }

        /// Connect to daemon at custom socket path
        pub async fn connect_to(socket_path: &str) -> anyhow::Result<Self> {
            let stream = UnixStream::connect(Path::new(socket_path)).await?;
            Ok(Self { stream })
        }

        /// Send a request and receive response
        pub async fn send(&mut self, request: VeloRequest) -> anyhow::Result<VeloResponse> {
            // Serialize request
            let req_bytes = bincode::serialize(&request)?;
            let req_len = (req_bytes.len() as u32).to_le_bytes();

            // Send length + payload
            self.stream.write_all(&req_len).await?;
            self.stream.write_all(&req_bytes).await?;

            // Read response length
            let mut len_buf = [0u8; 4];
            self.stream.read_exact(&mut len_buf).await?;
            let resp_len = u32::from_le_bytes(len_buf) as usize;

            // Read response payload
            let mut resp_buf = vec![0u8; resp_len];
            self.stream.read_exact(&mut resp_buf).await?;

            // Deserialize response
            let response = bincode::deserialize(&resp_buf)?;
            Ok(response)
        }

        /// Handshake with daemon
        pub async fn handshake(&mut self) -> anyhow::Result<String> {
            let request = VeloRequest::Handshake {
                client_version: env!("CARGO_PKG_VERSION").to_string(),
            };
            match self.send(request).await? {
                VeloResponse::HandshakeAck { server_version } => Ok(server_version),
                VeloResponse::Error(e) => anyhow::bail!("Handshake failed: {}", e),
                _ => anyhow::bail!("Unexpected response"),
            }
        }

        /// Get daemon status
        pub async fn status(&mut self) -> anyhow::Result<String> {
            match self.send(VeloRequest::Status).await? {
                VeloResponse::StatusAck { status } => Ok(status),
                VeloResponse::Error(e) => anyhow::bail!("Status failed: {}", e),
                _ => anyhow::bail!("Unexpected response"),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_request_serialization() {
        let req = VeloRequest::Status;
        let bytes = bincode::serialize(&req).unwrap();
        let decoded: VeloRequest = bincode::deserialize(&bytes).unwrap();
        assert!(matches!(decoded, VeloRequest::Status));
    }

    #[test]
    fn test_response_serialization() {
        let resp = VeloResponse::StatusAck {
            status: "OK".to_string(),
        };
        let bytes = bincode::serialize(&resp).unwrap();
        let decoded: VeloResponse = bincode::deserialize(&bytes).unwrap();
        assert!(matches!(decoded, VeloResponse::StatusAck { .. }));
    }

    #[test]
    fn test_default_socket_path() {
        // Verify default socket path is set
        let path = default_socket_path();
        assert!(!path.is_empty());
        assert!(path.ends_with(".sock"));
    }
}
