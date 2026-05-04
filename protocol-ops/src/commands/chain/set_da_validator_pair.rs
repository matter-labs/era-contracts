use std::path::Path;

use anyhow::Context;
use clap::Parser;
use ethers::types::Address;
use serde::{Deserialize, Serialize};

use crate::commands::output::write_output_if_requested;
use crate::common::forge::{Forge, ForgeRunner, ForgeScriptArg};
use crate::common::logger;
use crate::common::SharedRunArgs;
use crate::types::L2DACommitmentScheme;

/// Set the DA validator pair for an L1-settling chain.
///
/// Drives `AdminFunctions.s.sol::setDAValidatorPair(bridgehub, chainId,
/// l1DaValidator, l2DaCommitmentScheme, false)` against a forked anvil,
/// emits a Gnosis Safe Transaction Builder JSON bundle via `--out`, and can
/// optionally dispatch it in-process via `--execute`. If prepared without
/// `--execute`, replay the bundle via `protocol-ops dev execute-safe` (or any
/// Safe-bundle-aware executor) to apply it.
///
/// Use case: post chain upgrade (e.g. v29 → v31), where the upgrade itself
/// resets the chain's L1 DA validator and the operator must re-set it
/// before the chain can commit batches.
///
/// For chains that settle on a gateway (rather than directly on L1), use
/// `chain gateway migrate-to` — the migrate-to flow already invokes the
/// gateway-aware variant (`setDAValidatorPairWithGateway`) as part of its
/// Phase 3.
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainSetDaValidatorPairArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemChainArgs,

    /// L1 DA validator contract address. The post-upgrade `RollupL1DAValidator`
    /// (or analogous) deployed by the ecosystem upgrade.
    #[clap(long)]
    pub l1_da_validator: Address,

    /// L2 DA commitment scheme. For Era v31+: `blobs-and-pubdata-keccak256`
    /// (rollup, EraVM). For ZKsync OS: `blobs-z-k-sync-os`. For
    /// no-DA validium chains: `empty-no-d-a`. Etc.
    #[clap(long, value_enum)]
    pub l2_da_commitment_scheme: L2DACommitmentScheme,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
}

#[derive(Serialize)]
struct ChainSetDaValidatorPairOutputPayload {
    chain_id: u64,
    admin_address: Address,
    l1_da_validator: Address,
    l2_da_commitment_scheme: L2DACommitmentScheme,
}

pub async fn run(args: ChainSetDaValidatorPairArgs) -> anyhow::Result<()> {
    let (eco, chain_id) = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;

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
        sig: "setDAValidatorPair(address,uint256,address,uint8,bool)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Ffi);
    // Broadcast against the anvil fork so Forge records txs into its run
    // file — protocol-ops extracts those into the Safe bundle.
    script_args.add_arg(ForgeScriptArg::Broadcast);
    // `_shouldSend = true` so the script actually invokes
    // `Utils.adminExecuteCalls` and produces broadcast records.
    script_args.additional_args.extend([
        format!("{:#x}", eco.bridgehub),
        chain_id.to_string(),
        format!("{:#x}", args.l1_da_validator),
        (args.l2_da_commitment_scheme as u8).to_string(),
        "true".to_string(),
    ]);

    let forge = Forge::new(&runner.foundry_scripts_path)
        .script(script_path, script_args)
        .with_wallet(&sender);

    logger::step(
        "Preparing set-da-validator-pair Safe bundle via AdminFunctions.s.sol (simulation)",
    );
    logger::info(format!("Bridgehub: {:#x}", eco.bridgehub));
    logger::info(format!("Chain ID: {chain_id}"));
    logger::info(format!("Admin address: {:#x}", admin_address));
    logger::info(format!("L1 DA validator: {:#x}", args.l1_da_validator));
    logger::info(format!(
        "L2 DA commitment scheme: {} ({})",
        args.l2_da_commitment_scheme, args.l2_da_commitment_scheme as u8,
    ));
    logger::info(format!("RPC URL: {}", args.shared.l1_rpc_url));

    runner
        .run(forge)
        .context("Failed to execute forge script for set-da-validator-pair")?;

    let empty_input = serde_json::json!({});
    let out_payload = ChainSetDaValidatorPairOutputPayload {
        chain_id,
        admin_address,
        l1_da_validator: args.l1_da_validator,
        l2_da_commitment_scheme: args.l2_da_commitment_scheme,
    };
    write_output_if_requested(
        "chain.set-da-validator-pair",
        &args.shared,
        &runner,
        &empty_input,
        &out_payload,
    )
    .await?;

    logger::success("set-da-validator-pair prepared");
    Ok(())
}
