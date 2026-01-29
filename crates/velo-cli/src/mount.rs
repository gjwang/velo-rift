use anyhow::{Context, Result};
use std::fs;
use std::path::Path;
#[cfg(feature = "fuse")]
use velo_cas::CasStore;
#[cfg(feature = "fuse")]
use velo_manifest::Manifest;

/// Execute the mount command
pub fn run(cas_root: &Path, manifest_path: &Path, mountpoint: &Path) -> Result<()> {
    if !manifest_path.exists() {
        anyhow::bail!("Manifest not found: {}", manifest_path.display());
    }

    if !cas_root.exists() {
        anyhow::bail!("CAS root not found: {}", cas_root.display());
    }

    // Ensure mountpoint exists
    if !mountpoint.exists() {
        fs::create_dir_all(mountpoint)
            .with_context(|| format!("Failed to create mountpoint: {}", mountpoint.display()))?;
    }

    println!("Mounting VeloFS...");
    println!("  Manifest:   {}", manifest_path.display());
    println!("  CAS:        {}", cas_root.display());
    println!("  Mountpoint: {}", mountpoint.display());
    println!("  Mode:       Read-Only");

    #[cfg(feature = "fuse")]
    {
        let cas = CasStore::new(cas_root)?;
        let manifest = Manifest::load(manifest_path)?;
        let fs = velo_fuse::VeloFs::new(&manifest, cas);
        
        // This will block until unmounted
        fs.mount(mountpoint)?;
    }

    #[cfg(not(feature = "fuse"))]
    {
        println!("⚠️  FUSE support disabled. Recompile with --features fuse to enable.");
        println!("    cargo build -p velo-cli --features fuse");
    }

    Ok(())
}
