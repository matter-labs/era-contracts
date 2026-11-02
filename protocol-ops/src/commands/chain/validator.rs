use alloy::primitives::{Address, U256};
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::abi::AdminFunctionsAbi;
use crate::common::addresses::{VALIDATOR_TIMELOCK_UPGRADER_ROLE, ZERO_ADDRESS};
use crate::common::logger;
use crate::common::SharedRunArgs;

/// Shared args for add-validator / remove-validator / grant-upgrader.
///
/// Runs `AdminFunctions.s.sol::updateValidator` (`grantValidatorTimelockRole` for
/// grant-upgrader) in the simulation + Safe-bundle
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
    /// Use `ZERO_ADDRESS` for Ownable ChainAdmin.
    #[clap(long, default_value = ZERO_ADDRESS)]
    pub access_control_restriction: Address,
    /// Validator address to add/remove, or the account to grant `UPGRADER_ROLE`
    #[clap(long)]
    pub validator_address: Address,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
}

#[derive(Clone, Copy, PartialEq)]
enum Action {
    Add,
    Remove,
    /// Only `UPGRADER_ROLE`, which the node needs for `ValidatorTimelock.upgradeChainFromVersion`.
    GrantUpgrader,
}

pub async fn run_add(args: ChainValidatorArgs) -> anyhow::Result<()> {
    run_update(args, Action::Add).await
}

pub async fn run_remove(args: ChainValidatorArgs) -> anyhow::Result<()> {
    run_update(args, Action::Remove).await
}

pub async fn run_grant_upgrader(args: ChainValidatorArgs) -> anyhow::Result<()> {
    run_update(args, Action::GrantUpgrader).await
}

async fn run_update(args: ChainValidatorArgs, action: Action) -> anyhow::Result<()> {
    let (bridgehub, chain_id) = args.topology.resolve()?;
    let mut runner = crate::common::forge::ForgeRunner::new(&args.shared)?;

    // `AdminFunctions.updateValidator` → `Utils.adminExecute` internally
    // `vm.startBroadcast(adminOwner)` (or the AccessControlRestriction default
    // admin when set), so Forge's sender must match that EOA for nonce tracking
    // on the anvil fork.
    let sender = runner
        .prepare_chain_admin_broadcaster(bridgehub, chain_id, args.access_control_restriction)
        .await?;
    let admin_address =
        crate::common::l1_contracts::resolve_chain_admin(&runner.rpc_url, bridgehub, chain_id)
            .await
            .context("resolving chain admin from L1")?;
    let validator_timelock = crate::common::l1_contracts::resolve_validator_timelock(
        &runner.rpc_url,
        bridgehub,
        chain_id,
    )
    .await
    .context("resolving validator timelock from L1")?;

    let (verb, command) = match action {
        Action::Add => ("Adding validator", "chain.add-validator"),
        Action::Remove => ("Removing validator", "chain.remove-validator"),
        Action::GrantUpgrader => ("Granting UPGRADER_ROLE", "chain.grant-upgrader"),
    };
    logger::step(format!("{verb} via AdminFunctions.s.sol (simulation)"));
    logger::info(format!("Chain admin: {:#x}", admin_address));
    logger::info(format!(
        "Access control restriction: {:#x}",
        args.access_control_restriction
    ));
    logger::info(format!("Validator timelock: {:#x}", validator_timelock));
    logger::info(format!("Chain ID: {}", chain_id));
    let grantee = if action == Action::GrantUpgrader {
        "Account"
    } else {
        "Validator address"
    };
    logger::info(format!("{grantee}: {:#x}", args.validator_address));
    logger::info(format!("RPC URL: {}", args.shared.l1_rpc_url));

    let script = match action {
        Action::GrantUpgrader => {
            runner.script_call(AdminFunctionsAbi::grantValidatorTimelockRoleCall {
                _bridgehub: bridgehub,
                _chainId: U256::from(chain_id),
                _adminAddr: admin_address,
                _accessControlRestriction: args.access_control_restriction,
                _validatorTimelock: validator_timelock,
                _role: VALIDATOR_TIMELOCK_UPGRADER_ROLE,
                _account: args.validator_address,
            })
        }
        _ => runner.script_call(AdminFunctionsAbi::updateValidatorCall {
            _adminAddr: admin_address,
            _accessControlRestriction: args.access_control_restriction,
            _validatorTimelock: validator_timelock,
            _chainId: U256::from(chain_id),
            _validatorAddress: args.validator_address,
            _addValidator: action == Action::Add,
        }),
    }
    .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
    .with_wallet(&sender);
    runner
        .run(script)
        .with_context(|| format!("Failed: {verb}"))?;

    let mut input = serde_json::json!({
        "admin_address": format!("{:#x}", admin_address),
        "access_control_restriction": format!("{:#x}", args.access_control_restriction),
        "validator_timelock": format!("{:#x}", validator_timelock),
        "chain_id": chain_id,
    });
    if action == Action::GrantUpgrader {
        input["account"] = format!("{:#x}", args.validator_address).into();
        input["role"] = format!("{:#x}", VALIDATOR_TIMELOCK_UPGRADER_ROLE).into();
    } else {
        input["validator_address"] = format!("{:#x}", args.validator_address).into();
        input["add_validator"] = (action == Action::Add).into();
    }
    crate::common::output::write_output_if_requested(
        command,
        &args.shared,
        &runner,
        &input,
        &serde_json::json!({}),
    )
    .await?;

    logger::success(format!("{verb}: prepared"));
    Ok(())
}
