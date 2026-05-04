use std::path::Path;

use anyhow::Context;
use clap::Parser;
use ethers::types::Address;
use serde::{Deserialize, Serialize};

use crate::commands::output::write_output_if_requested;
use crate::common::forge::{Forge, ForgeRunner, ForgeScriptArg};
use crate::common::logger;
use crate::common::SharedRunArgs;

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
    #[clap(long, default_value = "0x0000000000000000000000000000000000000000")]
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
    // The Solidity script executes via ChainAdmin, but broadcasts from the
    // ChainAdmin owner internally. Use that owner as Forge's sender so Foundry
    // tracks the correct nonce on the anvil fork.
    let sender = runner
        .prepare_chain_admin_owner(eco.bridgehub, chain_id)
        .await?;

    let script_path = Path::new("deploy-scripts/AdminFunctions.s.sol");
    let script_full_path = runner.foundry_scripts_path.join(script_path);
    if !script_full_path.exists() {
        anyhow::bail!("Script not found: {}", script_full_path.display());
    }

    let mut script_args = runner.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "upgradeChainFromCTM(address,address,address)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args.add_arg(ForgeScriptArg::GasLimit {
        gas_limit: crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT,
    });
    // Broadcast against the anvil fork so Forge records txs into its run
    // file — protocol-ops extracts those into the Safe bundle.
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.additional_args.extend([
        format!("{:#x}", chain_address),
        format!("{:#x}", admin_address),
        format!("{:#x}", args.access_control_restriction),
    ]);

    let forge = Forge::new(&runner.foundry_scripts_path)
        .script(script_path, script_args)
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
