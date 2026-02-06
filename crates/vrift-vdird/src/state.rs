//! Persistent daemon state management
//!
//! Stores last_scan time and other daemon state to disk for recovery after restart.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rkyv::Archive;
use serde::{Deserialize, Serialize};
use tracing::{debug, info, warn};

/// Daemon persistent state
#[derive(
    Debug, Clone, Serialize, Deserialize, Default, Archive, rkyv::Serialize, rkyv::Deserialize,
)]
#[rkyv(derive(Debug))]
pub struct DaemonState {
    /// Last compensation scan timestamp (seconds since epoch)
    pub last_scan_secs: u64,
    /// Number of files in manifest at last save
    pub manifest_entry_count: u64,
    /// Last commit timestamp
    pub last_commit_secs: u64,
}

impl DaemonState {
    /// Load state from file, or return default if not found
    pub fn load(path: &Path) -> Self {
        match fs::read(path) {
            Ok(data) => match rkyv::from_bytes::<Self, rkyv::rancor::Error>(&data) {
                Ok(state) => {
                    info!(path = %path.display(), "Loaded daemon state");
                    state
                }
                Err(e) => {
                    warn!(path = %path.display(), error = %e, "Failed to deserialize state, using default");
                    Self::default()
                }
            },
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                debug!(path = %path.display(), "No existing state file, using default");
                Self::default()
            }
            Err(e) => {
                warn!(path = %path.display(), error = %e, "Failed to read state file, using default");
                Self::default()
            }
        }
    }

    /// Save state to file
    pub fn save(&self, path: &Path) -> io::Result<()> {
        // Ensure parent directory exists
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }

        let data = rkyv::to_bytes::<rkyv::rancor::Error>(self)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.to_string()))?;

        // Write atomically via temp file
        let temp_path = path.with_extension("tmp");
        fs::write(&temp_path, data.as_slice())?;
        fs::rename(&temp_path, path)?;

        debug!(path = %path.display(), "Saved daemon state");
        Ok(())
    }

    /// Get last_scan as SystemTime
    pub fn last_scan(&self) -> SystemTime {
        if self.last_scan_secs == 0 {
            UNIX_EPOCH
        } else {
            UNIX_EPOCH + Duration::from_secs(self.last_scan_secs)
        }
    }

    /// Update last_scan to now
    pub fn update_last_scan(&mut self) {
        self.last_scan_secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
    }

    /// Update last_commit to now
    pub fn update_last_commit(&mut self) {
        self.last_commit_secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
    }
}

/// Clean orphan temp files from staging directory
///
/// Removes files older than `max_age_secs` to reclaim space after crashes.
/// Returns the number of files cleaned.
pub fn cleanup_orphan_staging(staging_base: &Path, max_age_secs: u64) -> io::Result<usize> {
    use std::time::Duration;

    if !staging_base.exists() {
        return Ok(0);
    }

    let threshold = SystemTime::now()
        .checked_sub(Duration::from_secs(max_age_secs))
        .unwrap_or(UNIX_EPOCH);

    let mut cleaned = 0;

    for entry in fs::read_dir(staging_base)? {
        let entry = match entry {
            Ok(e) => e,
            Err(_) => continue,
        };

        let path = entry.path();

        // Skip directories
        if path.is_dir() {
            continue;
        }

        // Check file age
        let meta = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };

        let modified = match meta.modified() {
            Ok(t) => t,
            Err(_) => continue,
        };

        if modified < threshold {
            if let Err(e) = fs::remove_file(&path) {
                warn!(path = %path.display(), error = %e, "Failed to remove orphan staging file");
            } else {
                info!(path = %path.display(), "Removed orphan staging file");
                cleaned += 1;
            }
        }
    }

    Ok(cleaned)
}

/// State file path for a project
pub fn state_path(project_root: &Path) -> PathBuf {
    project_root.join(".vrift").join("daemon_state.bin")
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_state_save_load() {
        let dir = tempdir().unwrap();
        let path = dir.path().join(".vrift").join("daemon_state.bin");

        let mut state = DaemonState::default();
        state.update_last_scan();
        state.manifest_entry_count = 42;
        state.save(&path).unwrap();

        let loaded = DaemonState::load(&path);
        assert_eq!(loaded.manifest_entry_count, 42);
        assert!(loaded.last_scan_secs > 0);
    }

    #[test]
    fn test_state_default_on_missing() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("nonexistent.bin");

        let state = DaemonState::load(&path);
        assert_eq!(state.last_scan_secs, 0);
    }
}
