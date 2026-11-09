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
    // .../contracts/protocol-ops -> go one level up to .../contracts
    manifest_dir
        .parent()
        .expect("Failed to resolve default contracts root")
        .to_path_buf()
}

pub fn path_to_foundry_scripts() -> PathBuf {
    path_from_root("l1-contracts")
}

/// Resolves the `l1-contracts` directory, trying `<root>/l1-contracts` first and then
/// `<root>/contracts/l1-contracts` as a fallback (for mono-repo layouts).
pub fn resolve_l1_contracts_path() -> anyhow::Result<PathBuf> {
    let repo_root = contracts_root();
    let direct = repo_root.join("l1-contracts");
    if direct.exists() {
        return Ok(direct);
    }
    let nested = repo_root.join("contracts").join("l1-contracts");
    if nested.exists() {
        return Ok(nested);
    }
    anyhow::bail!(
        "Could not resolve l1-contracts path under {} (tried {} and {})",
        repo_root.display(),
        direct.display(),
        nested.display()
    )
}
