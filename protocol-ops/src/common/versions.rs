// Expected tool versions; must match docker/protocol/Dockerfile ARGs.
const EXPECTED_YARN_VERSION: &str = "1.22.19";
const EXPECTED_FORGE_VERSION: &str = "1.3.5";
const EXPECTED_ANVIL_VERSION: &str = "1.5.1";

use anyhow::{Context, Result};
use xshell::{cmd, Shell};

use crate::utils::paths;

fn expected_node_version() -> Result<String> {
    let nvmrc = paths::path_from_root(".nvmrc");
    let s = std::fs::read_to_string(&nvmrc)
        .with_context(|| format!("read {}", nvmrc.display()))?;
    let s = s.trim().trim_start_matches('v');
    Ok(s.to_string())
}

pub fn assert_versions(shell: &Shell) -> Result<()> {
    let expected_node = expected_node_version()?;
    let node_v = cmd!(shell, "node --version")
        .read()
        .context("run `node --version`")?;
    if !node_v.trim().trim_start_matches('v').starts_with(expected_node.as_str()) {
        anyhow::bail!(
            "node version mismatch: expected to contain {:?} (from .nvmrc), got {:?}",
            expected_node,
            node_v.trim()
        );
    }

    let yarn_v = cmd!(shell, "yarn --version")
        .read()
        .context("run `yarn --version`")?;
    if !yarn_v.trim().contains(EXPECTED_YARN_VERSION) {
        anyhow::bail!(
            "yarn version mismatch: expected {:?}, got {:?}",
            EXPECTED_YARN_VERSION,
            yarn_v.trim()
        );
    }

    let forge_v = cmd!(shell, "forge --version")
        .read()
        .context("run `forge --version`")?;
    if !forge_v.contains("zksync") {
        anyhow::bail!(
            "forge version must contain \"zksync\" (foundry-zksync), got {:?}",
            forge_v.trim()
        );
    }
    if !forge_v.contains(EXPECTED_FORGE_VERSION) {
        anyhow::bail!(
            "forge version mismatch: expected to contain {:?}, got {:?}",
            EXPECTED_FORGE_VERSION,
            forge_v.trim()
        );
    }

    let cast_v = cmd!(shell, "cast --version")
        .read()
        .context("run `cast --version`")?;
    if !cast_v.contains("zksync") {
        anyhow::bail!(
            "cast version must contain \"zksync\" (foundry-zksync), got {:?}",
            cast_v.trim()
        );
    }

    let anvil_v = cmd!(shell, "anvil --version")
        .read()
        .context("run `anvil --version`")?;
    if !anvil_v.contains(EXPECTED_ANVIL_VERSION) {
        anyhow::bail!(
            "anvil version mismatch: expected to contain {:?}, got {:?}",
            EXPECTED_ANVIL_VERSION,
            anvil_v.trim()
        );
    }

    Ok(())
}
