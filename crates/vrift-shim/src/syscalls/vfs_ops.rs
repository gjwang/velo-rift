//! VFS Operations - RFC-0047 Manifest mutation via IPC
//!
//! Handles unlink, rmdir, rename for VFS paths by sending IPC
//! requests to the daemon to update the Manifest.
//!
//! Note: These functions are currently not used directly but provide
//! reference implementation for future VFS path operations.

#![allow(dead_code)]

use crate::state::ShimState;
use libc::c_int;

/// Set errno for error returns
unsafe fn set_errno(e: c_int) {
    #[cfg(target_os = "macos")]
    {
        *libc::__error() = e;
    }
    #[cfg(target_os = "linux")]
    {
        *libc::__errno_location() = e;
    }
}

/// RFC-0047: unlink for VFS paths
/// Sends ManifestRemove IPC to daemon instead of hitting real FS
pub(crate) unsafe fn unlink_vfs(path: &str, state: &ShimState) -> Option<c_int> {
    // Only handle VFS paths
    if !state.psfs_applicable(path) {
        return None;
    }

    // Check if file exists in manifest
    if state.query_manifest(path).is_none() {
        set_errno(libc::ENOENT);
        return Some(-1);
    }

    // Send ManifestRemove IPC
    match state.manifest_remove(path) {
        Ok(()) => Some(0),
        Err(_) => {
            set_errno(libc::EIO);
            Some(-1)
        }
    }
}

/// RFC-0047: rmdir for VFS paths
/// Sends ManifestRemove IPC to daemon for directory removal
pub(crate) unsafe fn rmdir_vfs(path: &str, state: &ShimState) -> Option<c_int> {
    // Only handle VFS paths
    if !state.psfs_applicable(path) {
        return None;
    }

    // Check if directory exists in manifest
    let entry = state.query_manifest(path);
    if entry.is_none() {
        set_errno(libc::ENOENT);
        return Some(-1);
    }

    // Send ManifestRemove IPC
    match state.manifest_remove(path) {
        Ok(()) => Some(0),
        Err(_) => {
            set_errno(libc::EIO);
            Some(-1)
        }
    }
}

/// RFC-0047: mkdir for VFS paths
/// Sends ManifestUpsert IPC to daemon to create directory entry
pub(crate) unsafe fn mkdir_vfs(path: &str, mode: libc::mode_t, state: &ShimState) -> Option<c_int> {
    // Only handle VFS paths
    if !state.psfs_applicable(path) {
        return None;
    }

    // Check if already exists
    if state.query_manifest(path).is_some() {
        set_errno(libc::EEXIST);
        return Some(-1);
    }

    // Send ManifestUpsert IPC for directory
    match state.manifest_mkdir(path, mode) {
        Ok(()) => Some(0),
        Err(_) => {
            set_errno(libc::EIO);
            Some(-1)
        }
    }
}
