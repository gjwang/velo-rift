//! # velo CLI
//!
//! Command-line interface for Velo Rift content-addressable filesystem.
//!
//! ## Commands
//!
//! - `velo ingest <dir>` - Import files to CAS and generate manifest
//! - `velo run <cmd>` - Execute command with LD_PRELOAD (placeholder)
//! - `velo status` - Display CAS statistics

use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use walkdir::WalkDir;

use velo_cas::CasStore;
use velo_manifest::{Manifest, VnodeEntry};

/// Velo Rift - Content-Addressable Virtual Filesystem
#[derive(Parser)]
#[command(name = "velo")]
#[command(version, about, long_about = None)]
struct Cli {
    /// CAS storage root directory
    #[arg(long, default_value = "/var/velo/the_source")]
    cas_root: PathBuf,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Import files from a directory into the CAS
    Ingest {
        /// Directory to ingest
        #[arg(value_name = "DIR")]
        directory: PathBuf,

        /// Output manifest file path
        #[arg(short, long, default_value = "velo.manifest")]
        output: PathBuf,

        /// Base path prefix in manifest (default: use directory name)
        #[arg(short, long)]
        prefix: Option<String>,
    },

    /// Execute a command with Velo VFS (placeholder)
    Run {
        /// Manifest file to use
        #[arg(short, long, default_value = "velo.manifest")]
        manifest: PathBuf,

        /// Command to execute
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        command: Vec<String>,
    },

    /// Display CAS statistics
    Status {
        /// Also show manifest statistics if a manifest file is provided
        #[arg(short, long)]
        manifest: Option<PathBuf>,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Ingest {
            directory,
            output,
            prefix,
        } => cmd_ingest(&cli.cas_root, &directory, &output, prefix.as_deref()),
        Commands::Run { manifest, command } => cmd_run(&manifest, &command),
        Commands::Status { manifest } => cmd_status(&cli.cas_root, manifest.as_deref()),
    }
}

/// Ingest a directory into the CAS and create a manifest
fn cmd_ingest(cas_root: &Path, directory: &Path, output: &Path, prefix: Option<&str>) -> Result<()> {
    // Validate input directory
    if !directory.exists() {
        anyhow::bail!("Directory does not exist: {}", directory.display());
    }
    if !directory.is_dir() {
        anyhow::bail!("Not a directory: {}", directory.display());
    }

    // Initialize CAS store
    let cas = CasStore::new(cas_root)
        .with_context(|| format!("Failed to initialize CAS at {}", cas_root.display()))?;

    // Determine path prefix
    let base_prefix = prefix.unwrap_or_else(|| {
        directory
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("root")
    });

    let mut manifest = Manifest::new();
    let mut files_ingested = 0u64;
    let mut bytes_ingested = 0u64;
    let mut unique_blobs = 0u64;

    println!("Ingesting {} into CAS...", directory.display());

    for entry in WalkDir::new(directory).into_iter().filter_map(|e| e.ok()) {
        let path = entry.path();
        let relative = path
            .strip_prefix(directory)
            .unwrap_or(path);

        // Build manifest path
        let manifest_path = if relative.as_os_str().is_empty() {
            format!("/{}", base_prefix)
        } else {
            format!("/{}/{}", base_prefix, relative.display())
        };

        let metadata = fs::metadata(path)?;
        let mtime = metadata
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0);

        if metadata.is_dir() {
            let vnode = VnodeEntry::new_directory(mtime, metadata.mode());
            manifest.insert(&manifest_path, vnode);
        } else if metadata.is_file() {
            // Store file content in CAS
            let content = fs::read(path)
                .with_context(|| format!("Failed to read file: {}", path.display()))?;
            
            let was_new = !cas.exists(&CasStore::compute_hash(&content));
            let hash = cas.store(&content)?;
            
            if was_new {
                unique_blobs += 1;
            }

            let vnode = VnodeEntry::new_file(hash, metadata.len(), mtime, metadata.mode());
            manifest.insert(&manifest_path, vnode);

            files_ingested += 1;
            bytes_ingested += metadata.len();
        }
    }

    // Save manifest
    manifest.save(output)
        .with_context(|| format!("Failed to save manifest to {}", output.display()))?;

    let stats = manifest.stats();
    let dedup_ratio = if files_ingested > 0 {
        100.0 * (1.0 - (unique_blobs as f64 / files_ingested as f64))
    } else {
        0.0
    };

    println!("\n✓ Ingestion complete");
    println!("  Files:       {}", stats.file_count);
    println!("  Directories: {}", stats.dir_count);
    println!("  Total size:  {} bytes", format_bytes(bytes_ingested));
    println!("  Unique blobs: {} ({:.1}% dedup)", unique_blobs, dedup_ratio);
    println!("  Manifest:    {}", output.display());

    Ok(())
}

/// Execute a command with Velo VFS (placeholder)
fn cmd_run(manifest: &Path, command: &[String]) -> Result<()> {
    if command.is_empty() {
        anyhow::bail!("No command specified");
    }

    if !manifest.exists() {
        anyhow::bail!("Manifest not found: {}", manifest.display());
    }

    // TODO: Implement LD_PRELOAD shim execution
    // For now, just print what would happen
    println!("⚠️  LD_PRELOAD shim not yet implemented");
    println!();
    println!("Would execute with Velo VFS:");
    println!("  Manifest: {}", manifest.display());
    println!("  Command:  {}", command.join(" "));
    println!();
    println!("For now, running command directly...");
    println!();

    // Run the command directly as a fallback
    let status = std::process::Command::new(&command[0])
        .args(&command[1..])
        .status()
        .with_context(|| format!("Failed to execute: {}", command[0]))?;

    std::process::exit(status.code().unwrap_or(1));
}

/// Display CAS and optionally manifest statistics
fn cmd_status(cas_root: &Path, manifest: Option<&Path>) -> Result<()> {
    println!("Velo Rift Status");
    println!("================");
    println!();

    // CAS statistics
    if cas_root.exists() {
        let cas = CasStore::new(cas_root)?;
        let stats = cas.stats()?;

        println!("CAS Store: {}", cas_root.display());
        println!("  Blobs:      {}", stats.blob_count);
        println!("  Total size: {}", format_bytes(stats.total_bytes));
    } else {
        println!("CAS Store: {} (not initialized)", cas_root.display());
    }

    // Manifest statistics
    if let Some(manifest_path) = manifest {
        println!();
        if manifest_path.exists() {
            let manifest = Manifest::load(manifest_path)?;
            let stats = manifest.stats();

            println!("Manifest: {}", manifest_path.display());
            println!("  Files:       {}", stats.file_count);
            println!("  Directories: {}", stats.dir_count);
            println!("  Total size:  {}", format_bytes(stats.total_size));
        } else {
            println!("Manifest: {} (not found)", manifest_path.display());
        }
    }

    Ok(())
}

/// Format bytes in human-readable form
fn format_bytes(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;

    if bytes >= GB {
        format!("{:.2} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.2} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.2} KB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}
