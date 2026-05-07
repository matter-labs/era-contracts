use anyhow::Context;
use clap::Parser;
use ethers::types::Address;
use serde::{Deserialize, Serialize};

use crate::commands::output::write_output_if_requested;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::SharedRunArgs;
use crate::config::forge_interface::script_params::ADMIN_FUNCTIONS_INVOCATION;
use crate::types::L2DACommitmentScheme;

/// Set the DA validator pair for an L1-settling chain.
///
/// Drives `AdminFunctions.s.sol::setDAValidatorPair(bridgehub, chainId,
/// l1DaValidator, l2DaCommitmentScheme, true)` against a forked anvil and
/// emits a Gnosis Safe Transaction Builder JSON bundle via `--out`. Replay
/// the bundle via `protocol-ops dev execute-safe` (or any Safe-bundle-aware
/// executor) to apply it.
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
    let (bridgehub, chain_id) = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;

    let admin_address =
        crate::common::l1_contracts::resolve_chain_admin(&runner.rpc_url, bridgehub, chain_id)
            .await
            .context("resolving chain admin from L1")?;
    // The Solidity script executes via ChainAdmin, but broadcasts from the
    // ChainAdmin owner internally. Use that owner as Forge's sender so Foundry
    // tracks the correct nonce on the anvil fork.
    let sender = runner
        .prepare_chain_admin_owner(bridgehub, chain_id)
        .await?;

    let forge = runner
        .with_script_call(
            &ADMIN_FUNCTIONS_INVOCATION,
            "setDAValidatorPair",
            (
                bridgehub,
                ethers::types::U256::from(chain_id),
                args.l1_da_validator,
                args.l2_da_commitment_scheme as u8,
                true,
            ),
        )?
        .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
        .with_wallet(&sender);

    logger::step(
        "Preparing set-da-validator-pair Safe bundle via AdminFunctions.s.sol (simulation)",
    );
    logger::info(format!("Bridgehub: {:#x}", bridgehub));
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
