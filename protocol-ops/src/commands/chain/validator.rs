use std::path::Path;

use anyhow::Context;
use clap::Parser;
use ethers::{
    contract::BaseContract,
    types::{Address, U256},
};
use lazy_static::lazy_static;
use serde::{Deserialize, Serialize};

use crate::abi::ADMINFUNCTIONSABI_ABI;
use crate::commands::output::write_output_if_requested;
use crate::common::{
    forge::{Forge, ForgeRunner, ForgeScriptArg},
    logger, SharedRunArgs,
};

lazy_static! {
    static ref ADMIN_FUNCTIONS: BaseContract = BaseContract::from(ADMINFUNCTIONSABI_ABI.clone());
}

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
    let mut runner = ForgeRunner::new(&args.shared)?;

    // Sender is always the chain admin — that's the only address whose
    // simulation authors a ChainAdmin.multicall with the intended semantics.
    let sender = runner.prepare_chain_admin(eco.bridgehub, chain_id).await?;
    let admin_address = sender.address;
    let validator_timelock = crate::common::l1_contracts::resolve_validator_timelock(
        &runner.rpc_url,
        eco.bridgehub,
        chain_id,
    )
    .await
    .context("resolving validator timelock from L1")?;

    let script_path = Path::new("deploy-scripts/AdminFunctions.s.sol");
    let script_full_path = runner.foundry_scripts_path.join(script_path);
    if !script_full_path.exists() {
        anyhow::bail!("Script not found: {}", script_full_path.display());
    }

    // ABI-encode the `updateValidator(...)` call once; pass it to forge as the
    // `--sig` value (hex-encoded). Same mechanism as ecosystem upgrade's
    // governance stages — lets us reuse AdminFunctions.sol's internal
    // `Utils.adminExecute` path (which `vm.startBroadcast(adminOwner)`s a
    // `ChainAdmin.multicall`) without needing a dedicated "prepare" Solidity
    // function.
    let calldata = ADMIN_FUNCTIONS
        .encode(
            "updateValidator",
            (
                admin_address,
                args.access_control_restriction,
                validator_timelock,
                U256::from(chain_id),
                args.validator_address,
                add,
            ),
        )
        .map_err(|e| anyhow::anyhow!("Failed to encode updateValidator calldata: {}", e))?;

    let mut script_args = runner.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: ethers::utils::hex::encode(&calldata),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Ffi);
    // `--broadcast` against the anvil fork produces no real-chain effect —
    // it just records the tx in forge's run file so protocol-ops can extract
    // it into the Safe bundle. Without this the Safe output would be empty.
    script_args.add_arg(ForgeScriptArg::Broadcast);

    let forge = Forge::new(&runner.foundry_scripts_path)
        .script(script_path, script_args)
        .with_wallet(&sender);

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

    runner
        .run(forge)
        .with_context(|| format!("Failed to {} validator", if add { "add" } else { "remove" }))?;

    let command = if add {
        "chain.add-validator"
    } else {
        "chain.remove-validator"
    };
    write_output_if_requested(
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
