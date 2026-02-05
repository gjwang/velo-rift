//! Shared ignore pattern configuration for Live Ingest
//!
//! Provides unified ignore patterns for FSWatch, CompensationScanner, and CLI ingest.

use std::path::Path;

/// Default ignore patterns shared across all ingest layers
pub const DEFAULT_IGNORE_PATTERNS: &[&str] = &[
    ".git",
    ".vrift",
    "target",
    "node_modules",
    ".DS_Store",
    "__pycache__",
    ".pytest_cache",
    "*.pyc",
    ".idea",
    ".vscode",
];

/// Ignore pattern matcher
#[derive(Debug, Clone)]
pub struct IgnoreMatcher {
    patterns: Vec<String>,
}

impl Default for IgnoreMatcher {
    fn default() -> Self {
        Self::new()
    }
}

impl IgnoreMatcher {
    /// Create a new matcher with default patterns
    pub fn new() -> Self {
        Self {
            patterns: DEFAULT_IGNORE_PATTERNS
                .iter()
                .map(|s| s.to_string())
                .collect(),
        }
    }

    /// Create a matcher with custom patterns (plus defaults)
    pub fn with_patterns(extra_patterns: &[String]) -> Self {
        let mut patterns: Vec<String> = DEFAULT_IGNORE_PATTERNS
            .iter()
            .map(|s| s.to_string())
            .collect();
        patterns.extend(extra_patterns.iter().cloned());
        Self { patterns }
    }

    /// Check if a path should be ignored
    pub fn should_ignore(&self, path: &Path) -> bool {
        for pattern in &self.patterns {
            // Glob pattern (e.g., *.pyc)
            if let Some(suffix) = pattern.strip_prefix('*') {
                if path
                    .extension()
                    .is_some_and(|ext| format!(".{}", ext.to_string_lossy()) == suffix)
                {
                    return true;
                }
            }
            // Directory/file name match
            else if path
                .components()
                .any(|c| c.as_os_str().to_string_lossy() == *pattern)
            {
                return true;
            }
        }
        false
    }

    /// Get the patterns
    pub fn patterns(&self) -> &[String] {
        &self.patterns
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn test_ignore_git() {
        let matcher = IgnoreMatcher::new();
        assert!(matcher.should_ignore(&PathBuf::from("/project/.git/config")));
        assert!(matcher.should_ignore(&PathBuf::from(".git")));
    }

    #[test]
    fn test_ignore_target() {
        let matcher = IgnoreMatcher::new();
        assert!(matcher.should_ignore(&PathBuf::from("project/target/debug/app")));
    }

    #[test]
    fn test_ignore_glob_pyc() {
        let matcher = IgnoreMatcher::new();
        assert!(matcher.should_ignore(&PathBuf::from("script.pyc")));
        assert!(!matcher.should_ignore(&PathBuf::from("script.py")));
    }

    #[test]
    fn test_no_ignore_regular() {
        let matcher = IgnoreMatcher::new();
        assert!(!matcher.should_ignore(&PathBuf::from("src/main.rs")));
        assert!(!matcher.should_ignore(&PathBuf::from("package.json")));
    }
}
