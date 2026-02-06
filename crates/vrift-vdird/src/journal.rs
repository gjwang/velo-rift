//! Reingest Journal for Crash Recovery
//!
//! Records intent before reingest operations and clears on completion,
//! enabling idempotent recovery after crashes.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, BufReader, BufWriter};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rkyv::Archive;
use serde::{Deserialize, Serialize};
use tracing::{debug, info, warn};

/// Journal entry for a pending reingest operation
#[derive(Debug, Clone, Serialize, Deserialize, Archive, rkyv::Serialize, rkyv::Deserialize)]
#[rkyv(derive(Debug))]
pub struct JournalEntry {
    /// Virtual path being reingested
    pub vpath: String,
    /// Path to temp file (may no longer exist after crash)
    pub temp_path: String,
    /// CAS hash if ingest completed (Some = CAS done, VDir pending)
    pub cas_hash: Option<[u8; 32]>,
    /// Timestamp when operation started (seconds since epoch)
    pub started_at: u64,
}

/// Reingest journal for crash recovery
pub struct ReingestJournal {
    /// Path to journal file
    path: PathBuf,
    /// In-memory entries
    entries: HashMap<String, JournalEntry>,
}

impl ReingestJournal {
    /// Open or create journal at the given path
    pub fn open(path: &Path) -> io::Result<Self> {
        let entries = if path.exists() {
            match File::open(path) {
                Ok(file) => {
                    let reader = BufReader::new(file);
                    let mut data = Vec::new();
                    std::io::Read::read_to_end(&mut reader.into_inner(), &mut data).ok();
                    match rkyv::from_bytes::<HashMap<String, JournalEntry>, rkyv::rancor::Error>(
                        &data,
                    ) {
                        Ok(entries) => entries,
                        Err(e) => {
                            warn!(error = %e, "Failed to deserialize journal, starting fresh");
                            HashMap::new()
                        }
                    }
                }
                Err(e) => {
                    warn!(error = %e, "Failed to open journal, starting fresh");
                    HashMap::new()
                }
            }
        } else {
            HashMap::new()
        };

        Ok(Self {
            path: path.to_path_buf(),
            entries,
        })
    }

    /// Record intent to reingest a file
    pub fn record(&mut self, vpath: &str, temp_path: &str) -> io::Result<()> {
        let entry = JournalEntry {
            vpath: vpath.to_string(),
            temp_path: temp_path.to_string(),
            cas_hash: None,
            started_at: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0),
        };

        self.entries.insert(vpath.to_string(), entry);
        self.flush()?;

        debug!(vpath, temp_path, "Recorded reingest intent");
        Ok(())
    }

    /// Update entry with CAS hash after successful CAS ingest
    pub fn set_cas_hash(&mut self, vpath: &str, hash: [u8; 32]) -> io::Result<()> {
        if let Some(entry) = self.entries.get_mut(vpath) {
            entry.cas_hash = Some(hash);
            self.flush()?;
            debug!(vpath, "Updated journal with CAS hash");
        }
        Ok(())
    }

    /// Mark reingest as complete and remove from journal
    pub fn complete(&mut self, vpath: &str) -> io::Result<()> {
        if self.entries.remove(vpath).is_some() {
            self.flush()?;
            debug!(vpath, "Removed completed reingest from journal");
        }
        Ok(())
    }

    /// Get pending entries for recovery
    pub fn pending_entries(&self) -> Vec<&JournalEntry> {
        self.entries.values().collect()
    }

    /// Recover pending reingests that have CAS hash but weren't completed
    ///
    /// Returns entries where:
    /// - cas_hash is Some (CAS ingest completed)
    /// - entry was not removed (VDir update may have failed)
    pub fn recoverable_entries(&self) -> Vec<&JournalEntry> {
        self.entries
            .values()
            .filter(|e| e.cas_hash.is_some())
            .collect()
    }

    /// Remove stale entries older than max_age_secs
    pub fn cleanup_stale(&mut self, max_age_secs: u64) -> io::Result<usize> {
        let threshold = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs().saturating_sub(max_age_secs))
            .unwrap_or(0);

        let stale_keys: Vec<String> = self
            .entries
            .iter()
            .filter(|(_, e)| e.started_at < threshold)
            .map(|(k, _)| k.clone())
            .collect();

        let count = stale_keys.len();
        for key in stale_keys {
            self.entries.remove(&key);
        }

        if count > 0 {
            self.flush()?;
            info!(count, "Cleaned stale journal entries");
        }

        Ok(count)
    }

    /// Flush journal to disk
    fn flush(&self) -> io::Result<()> {
        // Ensure parent directory exists
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }

        // Write atomically via temp file
        let temp_path = self.path.with_extension("tmp");
        let file = File::create(&temp_path)?;
        let mut writer = BufWriter::new(file);
        let data = rkyv::to_bytes::<rkyv::rancor::Error>(&self.entries)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.to_string()))?;
        std::io::Write::write_all(&mut writer, &data)?;

        fs::rename(&temp_path, &self.path)?;
        Ok(())
    }

    /// Check if journal has pending entries
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Get number of pending entries
    pub fn len(&self) -> usize {
        self.entries.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_journal_record_complete() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("journal.bin");

        let mut journal = ReingestJournal::open(&path).unwrap();
        assert!(journal.is_empty());

        // Record
        journal
            .record("src/main.rs", "/tmp/staging/123.tmp")
            .unwrap();
        assert_eq!(journal.len(), 1);

        // Set CAS hash
        journal.set_cas_hash("src/main.rs", [1; 32]).unwrap();
        assert_eq!(journal.recoverable_entries().len(), 1);

        // Complete
        journal.complete("src/main.rs").unwrap();
        assert!(journal.is_empty());
    }

    #[test]
    fn test_journal_persistence() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("journal.bin");

        // Write
        {
            let mut journal = ReingestJournal::open(&path).unwrap();
            journal.record("file.txt", "/tmp/file.tmp").unwrap();
            journal.set_cas_hash("file.txt", [42; 32]).unwrap();
        }

        // Reopen and verify
        {
            let journal = ReingestJournal::open(&path).unwrap();
            assert_eq!(journal.len(), 1);
            let recoverable = journal.recoverable_entries();
            assert_eq!(recoverable.len(), 1);
            assert_eq!(recoverable[0].vpath, "file.txt");
            assert_eq!(recoverable[0].cas_hash, Some([42; 32]));
        }
    }

    #[test]
    fn test_journal_cleanup_stale() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("journal.bin");

        let mut journal = ReingestJournal::open(&path).unwrap();

        // Add entry with old timestamp
        let old_entry = JournalEntry {
            vpath: "old.txt".to_string(),
            temp_path: "/tmp/old.tmp".to_string(),
            cas_hash: None,
            started_at: 0, // Very old
        };
        journal.entries.insert("old.txt".to_string(), old_entry);
        journal.flush().unwrap();

        // Add recent entry
        journal.record("new.txt", "/tmp/new.tmp").unwrap();

        // Cleanup entries older than 1 hour
        let cleaned = journal.cleanup_stale(3600).unwrap();
        assert_eq!(cleaned, 1);
        assert_eq!(journal.len(), 1);
        assert!(journal.entries.contains_key("new.txt"));
    }
}
