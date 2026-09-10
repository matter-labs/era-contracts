use std::path::Path;
use std::process::Command;

use anyhow::{bail, Context, Result};

use crate::common::{
    logger,
    paths::{contracts_root, resolve_l1_contracts_path},
};

/// Ensure all Forge artifact directories needed by `bootstrap` and `apply`
/// exist, building them automatically when they are missing.
///
/// Runs `forge build` in `l1-contracts/` and `da-contracts/` if their `out/`
/// directories are absent or incomplete.
pub fn check_required_artifacts() -> Result<()> {
    let l1 = resolve_l1_contracts_path()?;
    if !l1.join("out").exists() {
        forge_build(&l1)?;
    }

    // DeployCTM.s.sol reads EIP7702Checker and RollupL1DAValidator bytecodes
    // from da-contracts/out/. Without this, forge prints a cryptic
    // "not allowed to be accessed for read operations" error.
    let da = contracts_root().join("da-contracts");
    if !da.join("out").join("EIP7702Checker.sol").exists() {
        forge_build(&da)?;
    }

    Ok(())
}

/// Verify that the L1 RPC endpoint is reachable. Emits a clear, actionable
/// error when the connection fails — including the exact `anvil` command for
/// local development setups.
pub fn check_l1_connectivity(rpc_url: &str) -> Result<()> {
    crate::common::ethereum::query_chain_id_sync(rpc_url).map(|_| ()).map_err(|_| {
        if is_local_rpc(rpc_url) {
            anyhow::anyhow!(
                "Cannot connect to L1 at {rpc_url}.\n\n\
                 For local development, start a local Anvil node in a separate terminal:\n\n\
                 \x20  anvil --chain-id 31337 --preserve-historical-states --disable-block-gas-limit \\\n\
                 \x20    --dump-state l1-state.json\n\n\
                 Then re-run this command."
            )
        } else {
            anyhow::anyhow!(
                "Cannot connect to L1 at {rpc_url}.\n\
                 Check that the RPC URL is correct and the node is reachable."
            )
        }
    })
}

/// Return true when the RPC URL points to a local node (localhost / 127.0.0.1).
/// Used to decide whether `anvil_setBalance` calls are safe to make.
pub fn is_local_rpc(rpc_url: &str) -> bool {
    rpc_url.contains("localhost") || rpc_url.contains("127.0.0.1")
}

// ---------------------------------------------------------------------------

pub fn forge_build(dir: &Path) -> Result<()> {
    if !dir.exists() {
        bail!(
            "Directory not found: {}\n\
             Ensure PROTOCOL_CONTRACTS_ROOT points to the era-contracts repository root.",
            dir.display()
        );
    }

    logger::step(format!("Building contracts in {}...", dir.display()));

    let status = Command::new("forge")
        .arg("build")
        .current_dir(dir)
        .status()
        .with_context(|| {
            format!(
                "failed to spawn `forge build` in {} — is forge installed?",
                dir.display()
            )
        })?;

    if !status.success() {
        bail!(
            "`forge build` failed in {} (exit {})",
            dir.display(),
            status.code().unwrap_or(-1)
        );
    }

    logger::success(format!("  {} built", dir.display()));
    Ok(())
}
