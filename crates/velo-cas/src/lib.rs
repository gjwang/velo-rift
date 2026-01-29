//! # velo-cas
//!
//! Content-Addressable Storage (CAS) implementation for Velo Rift.
//!
//! The CAS uses BLAKE3 hashing with a 2-character prefix fan-out directory layout
//! for efficient file organization and lookup.
//!
//! ## Directory Layout
//!
//! ```text
//! /var/velo/the_source/
//! ├── a8/
//! │   └── f9c1d2e3...  # Full hash as filename
//! └── b2/
//!     └── d3e4f5a6...
//! ```

use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use thiserror::Error;

/// BLAKE3 hash type (32 bytes)
pub type Blake3Hash = [u8; 32];

/// Errors that can occur during CAS operations
#[derive(Error, Debug)]
pub enum CasError {
    #[error("I/O error: {0}")]
    Io(#[from] io::Error),

    #[error("Blob not found: {hash}")]
    NotFound { hash: String },

    #[error("Hash mismatch: expected {expected}, got {actual}")]
    HashMismatch { expected: String, actual: String },
}

pub type Result<T> = std::result::Result<T, CasError>;

/// Content-Addressable Storage store
///
/// Stores blobs indexed by their BLAKE3 hash with a 2-char prefix fan-out.
#[derive(Debug, Clone)]
pub struct CasStore {
    root: PathBuf,
}

impl CasStore {
    /// Create a new CAS store at the given root directory.
    ///
    /// The directory will be created if it doesn't exist.
    pub fn new<P: AsRef<Path>>(root: P) -> Result<Self> {
        let root = root.as_ref().to_path_buf();
        fs::create_dir_all(&root)?;
        Ok(Self { root })
    }

    /// Create a CAS store at the default location (`/var/velo/the_source/`).
    pub fn default_location() -> Result<Self> {
        Self::new("/var/velo/the_source")
    }

    /// Compute the BLAKE3 hash of the given bytes.
    #[inline]
    pub fn compute_hash(data: &[u8]) -> Blake3Hash {
        *blake3::hash(data).as_bytes()
    }

    /// Convert a hash to its hex string representation.
    #[inline]
    pub fn hash_to_hex(hash: &Blake3Hash) -> String {
        hash.iter().map(|b| format!("{:02x}", b)).collect()
    }

    /// Parse a hex string into a hash.
    pub fn hex_to_hash(hex: &str) -> Option<Blake3Hash> {
        if hex.len() != 64 {
            return None;
        }
        let mut hash = [0u8; 32];
        for (i, chunk) in hex.as_bytes().chunks(2).enumerate() {
            let s = std::str::from_utf8(chunk).ok()?;
            hash[i] = u8::from_str_radix(s, 16).ok()?;
        }
        Some(hash)
    }

    /// Get the path where a blob with the given hash would be stored.
    fn blob_path(&self, hash: &Blake3Hash) -> PathBuf {
        let hex = Self::hash_to_hex(hash);
        let prefix = &hex[..2];
        self.root.join(prefix).join(&hex)
    }

    /// Store bytes in the CAS, returning the content hash.
    ///
    /// If the content already exists, this is a no-op (deduplication).
    pub fn store(&self, data: &[u8]) -> Result<Blake3Hash> {
        let hash = Self::compute_hash(data);
        let path = self.blob_path(&hash);

        // Deduplication: skip if already exists
        if path.exists() {
            return Ok(hash);
        }

        // Create prefix directory
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }

        // Write atomically using temp file + rename
        let temp_path = path.with_extension("tmp");
        let mut file = File::create(&temp_path)?;
        file.write_all(data)?;
        file.sync_all()?;
        fs::rename(&temp_path, &path)?;

        Ok(hash)
    }

    /// Store a file in the CAS by reading from the filesystem.
    pub fn store_file<P: AsRef<Path>>(&self, path: P) -> Result<Blake3Hash> {
        let data = fs::read(path)?;
        self.store(&data)
    }

    /// Retrieve bytes from the CAS by hash.
    pub fn get(&self, hash: &Blake3Hash) -> Result<Vec<u8>> {
        let path = self.blob_path(hash);
        if !path.exists() {
            return Err(CasError::NotFound {
                hash: Self::hash_to_hex(hash),
            });
        }

        let mut file = File::open(&path)?;
        let mut data = Vec::new();
        file.read_to_end(&mut data)?;

        // Verify hash on read (integrity check)
        let actual_hash = Self::compute_hash(&data);
        if actual_hash != *hash {
            return Err(CasError::HashMismatch {
                expected: Self::hash_to_hex(hash),
                actual: Self::hash_to_hex(&actual_hash),
            });
        }

        Ok(data)
    }

    /// Check if a blob exists in the CAS.
    pub fn exists(&self, hash: &Blake3Hash) -> bool {
        self.blob_path(hash).exists()
    }

    /// Get the root path of the CAS.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Get statistics about the CAS.
    pub fn stats(&self) -> Result<CasStats> {
        let mut blob_count = 0u64;
        let mut total_bytes = 0u64;

        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            if entry.file_type()?.is_dir() {
                for blob in fs::read_dir(entry.path())? {
                    let blob = blob?;
                    if blob.file_type()?.is_file() {
                        // Skip temp files
                        if blob.path().extension().is_some_and(|ext| ext == "tmp") {
                            continue;
                        }
                        blob_count += 1;
                        total_bytes += blob.metadata()?.len();
                    }
                }
            }
        }

        Ok(CasStats {
            blob_count,
            total_bytes,
        })
    }
}

/// Statistics about the CAS store
#[derive(Debug, Clone, Default)]
pub struct CasStats {
    /// Number of unique blobs stored
    pub blob_count: u64,
    /// Total bytes stored
    pub total_bytes: u64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_store_and_retrieve() {
        let temp = TempDir::new().unwrap();
        let cas = CasStore::new(temp.path()).unwrap();

        let data = b"Hello, Velo!";
        let hash = cas.store(data).unwrap();

        let retrieved = cas.get(&hash).unwrap();
        assert_eq!(retrieved, data);
    }

    #[test]
    fn test_deduplication() {
        let temp = TempDir::new().unwrap();
        let cas = CasStore::new(temp.path()).unwrap();

        let data = b"Duplicate content";
        let hash1 = cas.store(data).unwrap();
        let hash2 = cas.store(data).unwrap();

        assert_eq!(hash1, hash2);

        let stats = cas.stats().unwrap();
        assert_eq!(stats.blob_count, 1);
    }

    #[test]
    fn test_not_found() {
        let temp = TempDir::new().unwrap();
        let cas = CasStore::new(temp.path()).unwrap();

        let fake_hash = [0u8; 32];
        let result = cas.get(&fake_hash);
        assert!(matches!(result, Err(CasError::NotFound { .. })));
    }

    #[test]
    fn test_hash_to_hex_roundtrip() {
        let data = b"test data";
        let hash = CasStore::compute_hash(data);
        let hex = CasStore::hash_to_hex(&hash);
        let parsed = CasStore::hex_to_hash(&hex).unwrap();
        assert_eq!(hash, parsed);
    }

    #[test]
    fn test_empty_file() {
        let temp = TempDir::new().unwrap();
        let cas = CasStore::new(temp.path()).unwrap();

        let data = b"";
        let hash = cas.store(data).unwrap();
        let retrieved = cas.get(&hash).unwrap();
        assert!(retrieved.is_empty());
    }
}
