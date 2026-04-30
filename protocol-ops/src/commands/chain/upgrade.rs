use anyhow::Context;
use clap::Parser;
use ethers::types::Address;
use serde::{Deserialize, Serialize};

use crate::commands::output::write_output_if_requested;
use crate::common::addresses::ZERO_ADDRESS;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::SharedRunArgs;
use crate::config::forge_interface::script_params::ADMIN_FUNCTIONS_INVOCATION;

/// Chain-level CTM upgrade, prepare-only.
///
/// Drives `AdminFunctions.s.sol::upgradeChainFromCTM(chain, admin, acr)`
/// against a forked anvil (auto-impersonation), emits a Gnosis Safe
/// Transaction Builder JSON bundle via `--out`, and never
/// broadcasts. Replay the bundle via `protocol-ops dev execute-safe` (or any
/// Safe-bundle-aware executor) to apply it.
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainUpgradeArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemChainArgs,

    /// AccessControlRestriction contract address. Defaults to `0x0…0` for
    /// Ownable ChainAdmin deployments; pass explicitly when the chain uses
    /// an ACR.
    #[clap(long, default_value = ZERO_ADDRESS)]
    pub access_control_restriction: Address,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
}

#[derive(Serialize)]
struct ChainUpgradeOutputPayload {
    chain_address: Address,
    admin_address: Address,
    access_control_restriction: Address,
}

pub async fn run(args: ChainUpgradeArgs) -> anyhow::Result<()> {
    let (bridgehub, chain_id) = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;

    let chain_address =
        crate::common::l1_contracts::resolve_zk_chain(&runner.rpc_url, bridgehub, chain_id)
            .await
            .context("resolving chain diamond proxy from L1")?;
    // Sender is always the chain admin.
    let sender = runner.prepare_chain_admin(bridgehub, chain_id).await?;
    let admin_address = sender.address;

    let forge = runner
        .with_script_call(
            &ADMIN_FUNCTIONS_INVOCATION,
            "upgradeChainFromCTM",
            (
                chain_address,
                admin_address,
                args.access_control_restriction,
            ),
        )?
        .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
        // `--broadcast` against the anvil fork. In this mode the
        // target RPC is the anvil fork, so "broadcast" produces no real-chain
        // effect — it just records the tx in forge's run file so protocol-ops can
        // extract it into the Safe bundle. Without this the Safe output would be
        // empty.
        .with_wallet(&sender);

    logger::step("Preparing chain upgrade Safe bundle via AdminFunctions.s.sol (simulation)");
    logger::info(format!("Chain address: {:#x}", chain_address));
    logger::info(format!("Admin address: {:#x}", admin_address));
    logger::info(format!(
        "Access control restriction: {:#x}",
        args.access_control_restriction
    ));
    logger::info(format!("RPC URL: {}", args.shared.l1_rpc_url));

    runner
        .run(forge)
        .context("Failed to execute forge script for chain upgrade")?;

    let empty_input = serde_json::json!({});
    let out_payload = ChainUpgradeOutputPayload {
        chain_address,
        admin_address,
        access_control_restriction: args.access_control_restriction,
    };
    write_output_if_requested(
        "chain.upgrade",
        &args.shared,
        &runner,
        &empty_input,
        &out_payload,
    )
    .await?;

    logger::success("Chain upgrade prepared");
    Ok(())
}
