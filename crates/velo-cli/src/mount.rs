use anyhow::{Context, Result};
use clap::Args;
use std::fs;
use std::path::{Path, PathBuf};
#[cfg(feature = "fuse")]
use velo_cas::CasStore;
#[cfg(feature = "fuse")]
use velo_manifest::Manifest;

#[derive(Args, Debug)]
pub struct MountArgs {
    /// Manifest file to mount
    #[arg(short, long, default_value = "velo.manifest")]
    manifest: PathBuf,

    /// Mount point directory
    #[arg(value_name = "MOUNTPOINT")]
    mountpoint: PathBuf,
}

/// Execute the mount command
pub fn run(args: MountArgs) -> Result<()> {
    let cas_root = std::env::var("VELO_CAS_ROOT").unwrap_or_else(|_| "/var/velo/the_source".to_string());
    let cas_root = Path::new(&cas_root);
    let manifest_path = &args.manifest;
    let mountpoint = &args.mountpoint;
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
