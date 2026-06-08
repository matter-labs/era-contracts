use alloy::primitives::Address;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::SharedRunArgs;

#[derive(Serialize)]
struct ChainUpgradeOutput {
    chain_address: Address,
    admin_address: Address,
    access_control_restriction: Address,
}

/// Chain-level CTM upgrade.
///
/// Drives `AdminFunctions.s.sol::upgradeChainFromCTM` against a forked anvil
/// and emits a Gnosis Safe Transaction Builder JSON bundle via `--out`. Replay
/// the bundle via `protocol-ops dev execute-safe` to apply it.
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainUpgradeArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemChainArgs,

    /// AccessControlRestriction contract address. Defaults to `0x0…0` for
    /// Ownable ChainAdmin deployments.
    #[clap(long, default_value = "0x0000000000000000000000000000000000000000")]
    pub access_control_restriction: Address,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
}

pub async fn run(args: ChainUpgradeArgs) -> anyhow::Result<()> {
    let (eco, chain_id) = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;

    let chain_address =
        crate::common::l1_contracts::resolve_zk_chain(&runner.rpc_url, eco.bridgehub, chain_id)
            .await
            .context("resolving chain diamond proxy from L1")?;
    let admin_address =
        crate::common::l1_contracts::resolve_chain_admin(&runner.rpc_url, eco.bridgehub, chain_id)
            .await
            .context("resolving chain admin from L1")?;
    let sender = runner
        .prepare_chain_admin_owner(eco.bridgehub, chain_id)
        .await?;

    logger::step("Preparing chain upgrade ops via AdminFunctions.s.sol (simulation)");
    logger::info(format!("Chain address: {:#x}", chain_address));
    logger::info(format!("Admin address: {:#x}", admin_address));
    logger::info(format!(
        "Access control restriction: {:#x}",
        args.access_control_restriction
    ));
    logger::info(format!("RPC URL: {}", args.shared.l1_rpc_url));

    crate::common::admin_functions::upgrade_chain_from_ctm(
        &mut runner,
        &sender,
        chain_address,
        admin_address,
        args.access_control_restriction,
    )
    .context("Failed to run chain upgrade")?;

    crate::common::output::write_output_if_requested(
        "chain.upgrade",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &ChainUpgradeOutput {
            chain_address,
            admin_address,
            access_control_restriction: args.access_control_restriction,
        },
    )
    .await?;

    logger::success("Chain upgrade prepared");
    Ok(())
}
