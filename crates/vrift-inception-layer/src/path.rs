use libc::{c_char, c_int, AT_FDCWD};
use std::ffi::CStr;
use std::ptr;

use crate::state::FixedString;

/// RFC-0049: Unified path resolution for VFS domain.
/// Encapsulates absolute path and the corresponding manifest key.
#[derive(Debug, Clone)]
pub(crate) struct VfsPath {
    pub absolute: FixedString<1024>,
    pub manifest_key: FixedString<1024>,
    pub manifest_key_hash: u64,
}

pub(crate) struct PathResolver {
    pub vfs_prefix: FixedString<256>,
    pub project_root: FixedString<1024>,
}

impl PathResolver {
    pub fn new(vfs_prefix: &str, project_root: &str) -> Self {
        let mut prefix = FixedString::new();
        prefix.set(vfs_prefix);
        let mut root = FixedString::new();
        root.set(project_root);
        Self {
            vfs_prefix: prefix,
            project_root: root,
        }
    }

    /// Resolve an incoming path (absolute or relative) into a VfsPath.
    /// Returns None if the path is not within the VFS domain.
    pub fn resolve(&self, path: &str) -> Option<VfsPath> {
        // RFC-0050: Early exit if VFS is not configured
        if self.vfs_prefix.is_empty() {
            return None;
        }

        let mut abs_buf = [0u8; 1024];
        let mut abs_writer = crate::macros::StackWriter::new(&mut abs_buf);
        use std::fmt::Write;

        // 1. Resolve relative paths using real process cwd (POSIX semantics).
        //    Previous bug: used project_root, which broke build-scripts that chdir
        //    to external directories (e.g. ~/.cargo/registry/.../zerocopy-0.8.31/)
        //    and read relative "Cargo.toml" — that incorrectly resolved to
        //    {project_root}/Cargo.toml instead of the crate's own Cargo.toml.
        if !path.starts_with('/') {
            let mut found = false;
            crate::state::CACHED_CWD.with(|cache| {
                if let Some(ref fs) = *cache.borrow() {
                    let _ = write!(abs_writer, "{}/{}", fs.as_str(), path);
                    found = true;
                }
            });

            if !found {
                let mut cwd_buf = [0u8; 1024];
                #[cfg(target_os = "macos")]
                let cwd_ptr = unsafe {
                    crate::syscalls::macos_raw::raw_getcwd(
                        cwd_buf.as_mut_ptr() as *mut libc::c_char,
                        cwd_buf.len(),
                    )
                };
                #[cfg(target_os = "linux")]
                let cwd_ptr = unsafe {
                    crate::syscalls::linux_raw::raw_getcwd(
                        cwd_buf.as_mut_ptr() as *mut libc::c_char,
                        cwd_buf.len(),
                    )
                };
                if cwd_ptr.is_null() {
                    return None;
                }
                let cwd = unsafe { CStr::from_ptr(cwd_buf.as_ptr() as *const libc::c_char) };
                let cwd_str = cwd.to_str().ok()?;
                let _ = write!(abs_writer, "{}/{}", cwd_str, path);

                // Update cache for next time
                let mut fs = crate::state::FixedString::new();
                fs.set(cwd_str);
                crate::state::CACHED_CWD.with(|cache| {
                    *cache.borrow_mut() = Some(fs);
                });
            }
        } else {
            let _ = write!(abs_writer, "{}", path);
        };
        let abs_path = abs_writer.as_str();

        // 2. Normalize (handle .., ., //)
        let mut norm_buf = [0u8; 1024];
        let len = unsafe { raw_path_normalize(abs_path, &mut norm_buf)? };
        let normalized = std::str::from_utf8(&norm_buf[..len]).ok()?;

        // 3. Determine applicability and which prefix to strip
        let vfs_prefix_str = self.vfs_prefix.as_str();
        let proj_root_str = self.project_root.as_str();

        let mut matched_vfs = normalized.starts_with(vfs_prefix_str);

        #[cfg(target_os = "macos")]
        if !matched_vfs && normalized.starts_with("/tmp/") {
            let mut alt_buf = [0u8; 1024];
            let mut aw = crate::macros::StackWriter::new(&mut alt_buf);
            let _ = write!(aw, "/private{}", normalized);
            matched_vfs = aw.as_str().starts_with(vfs_prefix_str);
        }

        let mut matched_proj = false;
        if !self.project_root.is_empty() && normalized.starts_with(proj_root_str) {
            let boundary_char = normalized.as_bytes().get(proj_root_str.len()).copied();
            if boundary_char.is_none() || boundary_char == Some(b'/') {
                matched_proj = true;
            }
        }

        if !matched_vfs && !matched_proj {
            return None;
        }

        // RFC-0050: Explicitly exclude build-only directories
        if normalized.contains("/target/") || normalized.contains("/.git/") {
            return None;
        }

        // 4. Extract manifest key
        let mut key_fs = FixedString::<1024>::new();

        if matched_vfs {
            // Path matched VRIFT_VFS_PREFIX.
            // If the prefix is "virtual" (doesn't start with project root), keep it in the key.
            // If it's "physical" (points inside project root), strip it?
            // Actually, consistent with RFC-0050, we use the normalized path for virtual prefixes.
            if vfs_prefix_str.starts_with('/')
                && (proj_root_str.is_empty() || !vfs_prefix_str.starts_with(proj_root_str))
            {
                key_fs.set(normalized);
            } else {
                // It's a physical prefix, strip it if possible
                let key = normalized
                    .strip_prefix(vfs_prefix_str)
                    .unwrap_or(normalized);
                if !key.starts_with('/') {
                    let mut key_buf = [0u8; 1024];
                    let mut kw = crate::macros::StackWriter::new(&mut key_buf);
                    let _ = write!(kw, "/{}", key);
                    key_fs.set(kw.as_str());
                } else {
                    key_fs.set(key);
                }
            }
        } else {
            // Path matched project_root only (write-back track) or macOS /tmp variant
            let mut key_extracted = false;
            #[cfg(target_os = "macos")]
            if !normalized.starts_with(proj_root_str) && normalized.starts_with("/tmp/") {
                let mut alt_buf = [0u8; 1024];
                let mut aw = crate::macros::StackWriter::new(&mut alt_buf);
                let _ = write!(aw, "/private{}", normalized);
                let alt_normalized = aw.as_str();
                if alt_normalized.starts_with(proj_root_str) {
                    let key = alt_normalized.strip_prefix(proj_root_str).unwrap_or("");
                    if !key.starts_with('/') {
                        let mut key_buf = [0u8; 1024];
                        let mut kw = crate::macros::StackWriter::new(&mut key_buf);
                        let _ = write!(kw, "/{}", key);
                        key_fs.set(kw.as_str());
                    } else {
                        key_fs.set(key);
                    }
                    key_extracted = true;
                }
            }

            if !key_extracted {
                let key = normalized.strip_prefix(proj_root_str).unwrap_or("");
                if !key.starts_with('/') {
                    let mut key_buf = [0u8; 1024];
                    let mut kw = crate::macros::StackWriter::new(&mut key_buf);
                    let _ = write!(kw, "/{}", key);
                    key_fs.set(kw.as_str());
                } else {
                    key_fs.set(key);
                }
            }
        }

        crate::inception_log!("Path resolved to manifest key: '{}'", key_fs.as_str());

        let mut norm_fs = FixedString::<1024>::new();
        norm_fs.set(normalized);

        let manifest_key_hash = vrift_ipc::fnv1a_hash(key_fs.as_str());
        Some(VfsPath {
            absolute: norm_fs,
            manifest_key: key_fs,
            manifest_key_hash,
        })
    }
}

/// Robust path normalization without heap allocation (low-level).
/// Handles "..", ".", and duplicate slashes.
/// Returns the length of the normalized path in `out`.
pub(crate) unsafe fn raw_path_normalize(path: &str, out: &mut [u8]) -> Option<usize> {
    if path.is_empty() || out.is_empty() {
        return None;
    }

    let bytes = path.as_bytes();
    let mut out_idx = 0;

    // Always start with / if input is absolute
    if bytes[0] == b'/' {
        out[out_idx] = b'/';
        out_idx += 1;
    }

    let mut i = 0;
    while i < bytes.len() {
        // Skip multiple slashes
        while i < bytes.len() && bytes[i] == b'/' {
            i += 1;
        }
        if i == bytes.len() {
            break;
        }

        // Find component end
        let start = i;
        while i < bytes.len() && bytes[i] != b'/' {
            i += 1;
        }
        let component = &bytes[start..i];

        if component == b"." {
            continue;
        } else if component == b".." {
            if out_idx > 1 {
                // Backtrack to previous slash
                out_idx -= 1;
                while out_idx > 1 && out[out_idx - 1] != b'/' {
                    out_idx -= 1;
                }
            } else if out_idx == 1 && out[0] == b'/' {
                // At root, stay at root
                continue;
            }
        } else {
            // Add slash if not at root and last char isn't slash
            if out_idx > 0 && out[out_idx - 1] != b'/' {
                if out_idx < out.len() {
                    out[out_idx] = b'/';
                    out_idx += 1;
                } else {
                    return None;
                }
            }
            // Add component
            if out_idx + component.len() <= out.len() {
                ptr::copy_nonoverlapping(
                    component.as_ptr(),
                    out.as_mut_ptr().add(out_idx),
                    component.len(),
                );
                out_idx += component.len();
            } else {
                return None;
            }
        }
    }

    if out_idx == 0 {
        if bytes[0] == b'/' {
            out[0] = b'/';
        } else {
            out[0] = b'.';
        }
        out_idx = 1;
    }

    Some(out_idx)
}

/// RFC-0049: Generate virtual inode from path
/// Prevents st_ino collision when CAS dedup causes multiple logical files to share same blob
/// Uses a simple hash to generate unique inode per logical path
#[inline]
pub(crate) fn path_to_virtual_ino(path: &str) -> libc::ino_t {
    // Simple FNV-1a hash for O(1) inode generation
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in path.bytes() {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash as libc::ino_t
}

pub(crate) unsafe fn resolve_path_at(
    dirfd: c_int,
    path: *const c_char,
    out: &mut [u8],
) -> Option<usize> {
    let path_str = CStr::from_ptr(path).to_str().ok()?;
    if path_str.starts_with('/') {
        return raw_path_normalize(path_str, out);
    }
    if dirfd == AT_FDCWD {
        // Fallback to basic normalization if no complex resolver is available
        return raw_path_normalize(path_str, out);
    }
    // Cannot resolve relative path to arbitrary dirfd easily without OS help.
    None
}
