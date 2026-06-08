use alloy::primitives::Address;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::logger;
use crate::common::SharedRunArgs;

/// Shared args for add-validator / remove-validator.
///
/// Runs `AdminFunctions.s.sol::updateValidator` in the simulation + Safe-bundle
/// emission mode that every other admin-action command in protocol-ops uses.
/// No `--private-key` on this command. It emits a Safe Transaction Builder JSON
/// bundle via `--out`. The ops engineer (or the integration test harness)
/// replays it via `protocol-ops dev execute-safe`, a Gnosis Safe UI, or any
/// other bundle executor.
///
/// Forks the supplied `--l1-rpc-url` via anvil, runs the script against the
/// fork (no real chain mutation), and captures the intended txs into the
/// Safe bundle.
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainValidatorArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemChainArgs,

    /// AccessControlRestriction contract address.
    /// Use `0x0000000000000000000000000000000000000000` for Ownable ChainAdmin.
    #[clap(long, default_value = "0x0000000000000000000000000000000000000000")]
    pub access_control_restriction: Address,
    /// Validator address to add/remove
    #[clap(long)]
    pub validator_address: Address,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
}

pub async fn run_add(args: ChainValidatorArgs) -> anyhow::Result<()> {
    run_update(args, true).await
}

pub async fn run_remove(args: ChainValidatorArgs) -> anyhow::Result<()> {
    run_update(args, false).await
}

async fn run_update(args: ChainValidatorArgs, add: bool) -> anyhow::Result<()> {
    let (eco, chain_id) = args.topology.resolve()?;
    let mut runner = crate::common::forge::ForgeRunner::new(&args.shared)?;

    let owner = runner
        .prepare_chain_admin_owner(eco.bridgehub, chain_id)
        .await?;
    let admin_address =
        crate::common::l1_contracts::resolve_chain_admin(&runner.rpc_url, eco.bridgehub, chain_id)
            .await
            .context("resolving chain admin from L1")?;
    let validator_timelock = crate::common::l1_contracts::resolve_validator_timelock(
        &runner.rpc_url,
        eco.bridgehub,
        chain_id,
    )
    .await
    .context("resolving validator timelock from L1")?;

    let action = if add { "Adding" } else { "Removing" };
    logger::step(format!(
        "{action} validator via AdminFunctions.s.sol::updateValidator (simulation)"
    ));
    logger::info(format!("Chain admin: {:#x}", admin_address));
    logger::info(format!(
        "Access control restriction: {:#x}",
        args.access_control_restriction
    ));
    logger::info(format!("Validator timelock: {:#x}", validator_timelock));
    logger::info(format!("Chain ID: {}", chain_id));
    logger::info(format!("Validator address: {:#x}", args.validator_address));
    logger::info(format!("RPC URL: {}", args.shared.l1_rpc_url));

    let command = if add {
        "chain.add-validator"
    } else {
        "chain.remove-validator"
    };

    crate::common::admin_functions::update_validator(
        &mut runner,
        admin_address,
        &owner,
        args.access_control_restriction,
        validator_timelock,
        chain_id,
        args.validator_address,
        add,
    )
    .with_context(|| format!("Failed to {} validator", if add { "add" } else { "remove" }))?;

    crate::common::output::write_output_if_requested(
        command,
        &args.shared,
        &runner,
        &serde_json::json!({
            "admin_address": format!("{:#x}", admin_address),
            "access_control_restriction": format!("{:#x}", args.access_control_restriction),
            "validator_timelock": format!("{:#x}", validator_timelock),
            "chain_id": chain_id,
            "validator_address": format!("{:#x}", args.validator_address),
            "add_validator": add,
        }),
        &serde_json::json!({}),
    )
    .await?;

    let verb = if add {
        "add prepared"
    } else {
        "remove prepared"
    };
    logger::success(format!("Validator {verb}"));
    Ok(())
}
