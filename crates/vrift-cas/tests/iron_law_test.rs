#[cfg(test)]
mod tests {
    use std::fs;
    use tempfile::TempDir;
    use vrift_cas::{parallel_ingest, IngestMode};

    /// Verify "Iron Law Drift" Bug (Idempotency Bug)
    /// If a file already exists in CAS but is unprotected, re-ingest should restore protection.
    #[test]
    #[allow(clippy::permissions_set_readonly_false)]
    fn test_iron_law_idempotency() {
        let cas_dir = TempDir::new().unwrap();
        let source_dir = TempDir::new().unwrap();
        let cas_root = cas_dir.path();

        let file_path = source_dir.path().join("vulnerable_file.txt");
        fs::write(&file_path, "secret content").unwrap();

        // 1. Manually place file in CAS without protection (simulating legacy/corrupt state)
        // The correct BLAKE3 hash of "secret content" is cb18e580...
        let hash = "cb18e580a10f9fa598a703bbc284bbe6375bb8d37f204f1f7086d277bde818c1";
        let blob_path = cas_root
            .join("blake3")
            .join("cb")
            .join("18")
            .join(format!("{}_14.bin", hash));
        fs::create_dir_all(blob_path.parent().unwrap()).unwrap();
        fs::write(&blob_path, "secret content").unwrap();

        // Ensure it starts as writable
        let mut perms = fs::metadata(&blob_path).unwrap().permissions();
        perms.set_readonly(false);
        fs::set_permissions(&blob_path, perms).unwrap();

        println!(
            "Initial blob perms: {:?}",
            fs::metadata(&blob_path).unwrap().permissions()
        );

        // 2. Run standard ingest pipeline
        let files = vec![file_path.clone()];
        let results = parallel_ingest(&files, cas_root, IngestMode::SolidTier2);
        assert!(results[0].is_ok());

        // Verify was_new is false (blob already existed)
        let result = results[0].as_ref().unwrap();
        assert!(!result.was_new, "was_new should be false for existing blob");

        // 3. Verify if CAS blob is now enforced with protection
        // The fix ensures enforce_cas_invariant is called regardless of was_new
        let metadata = fs::metadata(&blob_path).unwrap();
        assert!(
            metadata.permissions().readonly(),
            "CAS blob must be set to READ-ONLY even if it already existed"
        );
    }
}
