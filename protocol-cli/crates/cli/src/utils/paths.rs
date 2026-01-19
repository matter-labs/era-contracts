use std::path::{Path, PathBuf};

/// Returns the root of the contracts repository.
pub fn contracts_root() -> PathBuf {
    if let Ok(path) = std::env::var("PROTOCOL_CONTRACTS_ROOT") {
        PathBuf::from(path)
    } else {
        default_contracts_root()
    }
}

/// Resolves a path relative to the contracts repository root.
pub fn path_from_root<P: AsRef<Path>>(relative: P) -> PathBuf {
    contracts_root().join(relative)
}

fn default_contracts_root() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // .../contracts/poc-protocol-cli/crates/cli -> go three levels up to .../contracts
    manifest_dir
        .parent()
        .and_then(|p| p.parent())
        .and_then(|p| p.parent())
        .expect("Failed to resolve default contracts root")
        .to_path_buf()
}
