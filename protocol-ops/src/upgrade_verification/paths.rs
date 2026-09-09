//! Repository-root path resolution, shared by every verifier version.
//!
//! Verification reads committed artifacts (`AllContractsHashes.json`, genesis configs) that
//! live at the repository root, and the tool must find them whether it is invoked from the
//! root, from `protocol-ops/`, or from a test's working directory.

use std::path::{Path, PathBuf};

/// Resolves `relative_path` against the repository root.
///
/// Walks up from the current directory looking for an existing match, so an invocation from
/// any subdirectory finds the same file. Falls back to `protocol-ops`'s parent, which is the
/// repository root by construction.
pub fn repo_relative_path(relative_path: impl AsRef<Path>) -> PathBuf {
    let relative_path = relative_path.as_ref();
    if relative_path.is_absolute() {
        return relative_path.to_path_buf();
    }

    if let Ok(current_dir) = std::env::current_dir() {
        for ancestor in current_dir.ancestors() {
            let candidate = ancestor.join(relative_path);
            if candidate.exists() {
                return candidate;
            }
        }
    }

    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("protocol-ops must be a direct child of the repository root")
        .join(relative_path)
}
