// Expected tool versions; must match docker/protocol/Dockerfile ARGs.
const EXPECTED_YARN_VERSION: &str = "1.22.19";
const EXPECTED_FORGE_VERSION: &str = "1.3.5";
const EXPECTED_ANVIL_VERSION: &str = "1.5.1";

use anyhow::{Context, Result};
use xshell::{cmd, Shell};

use crate::common::paths;

fn expected_node_version() -> Result<String> {
    let nvmrc = paths::path_from_root(".nvmrc");
    let s = std::fs::read_to_string(&nvmrc)
        .with_context(|| format!("read {}", nvmrc.display()))?;
    let s = s.trim().trim_start_matches('v');
    Ok(s.to_string())
}

/// Check tool versions, printing warnings for mismatches.
/// Returns Ok(()) even when versions don't match (non-fatal by default).
pub fn check_versions(shell: &Shell) {
    let mut warnings = Vec::new();

    match expected_node_version().and_then(|expected_node| {
        let node_v = cmd!(shell, "node --version")
            .read()
            .context("run `node --version`")?;
        if !node_v.trim().trim_start_matches('v').contains(expected_node.as_str()) {
            warnings.push(format!(
                "node version mismatch: expected to contain {:?} (from .nvmrc), got {:?}",
                expected_node,
                node_v.trim()
            ));
        }
        Ok(())
    }) {
        Ok(()) => {}
        Err(e) => warnings.push(format!("could not check node version: {e}")),
    }

    match cmd!(shell, "yarn --version").read() {
        Ok(yarn_v) => {
            if !yarn_v.trim().contains(EXPECTED_YARN_VERSION) {
                warnings.push(format!(
                    "yarn version mismatch: expected {:?}, got {:?}",
                    EXPECTED_YARN_VERSION,
                    yarn_v.trim()
                ));
            }
        }
        Err(e) => warnings.push(format!("could not check yarn version: {e}")),
    }

    match cmd!(shell, "forge --version").read() {
        Ok(forge_v) => {
            if !forge_v.contains("zksync") {
                warnings.push(format!(
                    "forge version must contain \"zksync\" (foundry-zksync), got {:?}",
                    forge_v.trim()
                ));
            }
            if !forge_v.contains(EXPECTED_FORGE_VERSION) {
                warnings.push(format!(
                    "forge version mismatch: expected to contain {:?}, got {:?}",
                    EXPECTED_FORGE_VERSION,
                    forge_v.trim()
                ));
            }
        }
        Err(e) => warnings.push(format!("could not check forge version: {e}")),
    }

    match cmd!(shell, "cast --version").read() {
        Ok(cast_v) => {
            if !cast_v.contains("zksync") {
                warnings.push(format!(
                    "cast version must contain \"zksync\" (foundry-zksync), got {:?}",
                    cast_v.trim()
                ));
            }
        }
        Err(e) => warnings.push(format!("could not check cast version: {e}")),
    }

    match cmd!(shell, "anvil --version").read() {
        Ok(anvil_v) => {
            if !anvil_v.contains(EXPECTED_ANVIL_VERSION) {
                warnings.push(format!(
                    "anvil version mismatch: expected to contain {:?}, got {:?}",
                    EXPECTED_ANVIL_VERSION,
                    anvil_v.trim()
                ));
            }
        }
        Err(e) => warnings.push(format!("could not check anvil version: {e}")),
    }

    for w in &warnings {
        eprintln!("  WARNING: {w}");
    }
}
