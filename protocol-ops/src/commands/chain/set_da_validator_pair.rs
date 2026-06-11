use alloy::primitives::Address;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::SharedRunArgs;
use crate::types::L2DACommitmentScheme;

#[derive(Serialize)]
struct SetDaValidatorPairOutput {
    chain_id: u64,
    admin_address: Address,
    l1_da_validator: Address,
    l2_da_commitment_scheme: L2DACommitmentScheme,
}

/// Set the DA validator pair for an L1-settling chain.
///
/// Drives `AdminFunctions.s.sol::setDAValidatorPair` against a forked anvil and
/// emits a Gnosis Safe Transaction Builder JSON bundle via `--out`. Replay the
/// bundle via `protocol-ops dev execute-safe` (or any Safe-bundle-aware executor)
/// to apply it.
///
/// For chains that settle on a gateway, use `chain gateway migrate-to`.
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainSetDaValidatorPairArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemChainArgs,

    /// L1 DA validator contract address.
    #[clap(long)]
    pub l1_da_validator: Address,

    /// L2 DA commitment scheme.
    #[clap(long, value_enum)]
    pub l2_da_commitment_scheme: L2DACommitmentScheme,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
}

pub async fn run(args: ChainSetDaValidatorPairArgs) -> anyhow::Result<()> {
    let (eco, chain_id) = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;

    let admin_address =
        crate::common::l1_contracts::resolve_chain_admin(&runner.rpc_url, eco.bridgehub, chain_id)
            .await
            .context("resolving chain admin from L1")?;
    let wallet = runner
        .prepare_chain_admin_owner(eco.bridgehub, chain_id)
        .await?;

    logger::step("Preparing set-da-validator-pair ops via AdminFunctions.s.sol (simulation)");
    logger::info(format!("Bridgehub: {:#x}", eco.bridgehub));
    logger::info(format!("Chain ID: {chain_id}"));
    logger::info(format!("Admin address: {:#x}", admin_address));
    logger::info(format!("L1 DA validator: {:#x}", args.l1_da_validator));
    logger::info(format!(
        "L2 DA commitment scheme: {} ({})",
        args.l2_da_commitment_scheme, args.l2_da_commitment_scheme as u8,
    ));
    logger::info(format!("RPC URL: {}", args.shared.l1_rpc_url));

    crate::common::admin_functions::set_da_validator_pair(
        &mut runner,
        &wallet,
        chain_id,
        eco.bridgehub,
        args.l1_da_validator,
        args.l2_da_commitment_scheme,
    )
    .context("Failed to run set-da-validator-pair")?;

    crate::common::output::write_output_if_requested(
        "chain.set-da-validator-pair",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &SetDaValidatorPairOutput {
            chain_id,
            admin_address,
            l1_da_validator: args.l1_da_validator,
            l2_da_commitment_scheme: args.l2_da_commitment_scheme,
        },
    )
    .await?;

    logger::success("set-da-validator-pair prepared");
    Ok(())
}
