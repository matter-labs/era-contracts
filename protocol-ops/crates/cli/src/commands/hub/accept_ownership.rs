use clap::Parser;
use ethers::types::{Address, H256};
use protocol_ops_common::{
    forge::{ForgeArgs, ForgeRunner},
    logger,
};
use serde::{Deserialize, Serialize};
use xshell::Shell;

use crate::admin_functions::{accept_admin, accept_owner};
use crate::forge_ctx::{resolve_execution, ExecutionMode, ForgeContext};
use crate::utils::paths;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct HubAcceptOwnershipArgs {
    // Core ecosystem contract addresses
    #[clap(long, help = "Bridgehub proxy address")]
    pub bridgehub: Address,
    #[clap(long, help = "L1 Asset Router (shared bridge) proxy address")]
    pub asset_router: Address,
    #[clap(long, help = "STM deployment tracker proxy address")]
    pub stm_deployment_tracker: Address,
    #[clap(long, help = "Chain asset handler proxy address")]
    pub chain_asset_handler: Option<Address>,

    // Governance addresses
    #[clap(long, help = "Governance contract address")]
    pub governance: Address,
    #[clap(long, help = "Chain admin contract address")]
    pub chain_admin: Address,

    // Connection & auth
    #[clap(long, help = "L1 RPC URL", default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,
    #[clap(long, visible_alias = "pk", help = "Governor private key")]
    pub private_key: Option<H256>,
    #[clap(long, help = "Governor address (for simulation)")]
    pub sender: Option<Address>,
    #[clap(long, help = "Simulate against anvil fork (no on-chain changes)")]
    pub simulate: bool,
    #[clap(long, help = "Use dev defaults")]
    pub dev: bool,

    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

/// Input parameters for accepting ownership of hub contracts.
#[derive(Debug, Clone)]
pub struct AcceptOwnershipInput {
    pub bridgehub: Address,
    pub asset_router: Address,
    pub stm_deployment_tracker: Address,
    pub chain_asset_handler: Option<Address>,
    pub governance: Address,
    pub chain_admin: Address,
}

/// Accept ownership of hub contracts.
pub async fn accept_ownership(
    ctx: &mut ForgeContext<'_>,
    input: &AcceptOwnershipInput,
) -> anyhow::Result<()> {
    let governor_wallet = ctx.auth.to_wallet()?;

    // Accept ownership for Bridgehub
    logger::step("Accepting ownership of Bridgehub...");
    accept_owner(
        ctx.shell,
        ctx.runner,
        ctx.foundry_scripts_path,
        input.governance,
        &governor_wallet,
        input.bridgehub,
        ctx.forge_args,
        ctx.l1_rpc_url.to_string(),
    )
    .await?;

    logger::step("Accepting admin of Bridgehub...");
    accept_admin(
        ctx.shell,
        ctx.runner,
        ctx.foundry_scripts_path,
        input.chain_admin,
        &governor_wallet,
        input.bridgehub,
        ctx.forge_args,
        ctx.l1_rpc_url.to_string(),
    )
    .await?;

    // Accept ownership for L1 Asset Router (shared bridge)
    // Note: There is no admin in L1 asset router
    logger::step("Accepting ownership of L1 Asset Router...");
    accept_owner(
        ctx.shell,
        ctx.runner,
        ctx.foundry_scripts_path,
        input.governance,
        &governor_wallet,
        input.asset_router,
        ctx.forge_args,
        ctx.l1_rpc_url.to_string(),
    )
    .await?;

    // Accept ownership for STM deployment tracker
    logger::step("Accepting ownership of STM Deployment Tracker...");
    accept_owner(
        ctx.shell,
        ctx.runner,
        ctx.foundry_scripts_path,
        input.governance,
        &governor_wallet,
        input.stm_deployment_tracker,
        ctx.forge_args,
        ctx.l1_rpc_url.to_string(),
    )
    .await?;

    // Accept ownership for Chain Asset Handler (if provided)
    if let Some(chain_asset_handler) = input.chain_asset_handler {
        logger::step("Accepting ownership of Chain Asset Handler...");
        accept_owner(
            ctx.shell,
            ctx.runner,
            ctx.foundry_scripts_path,
            input.governance,
            &governor_wallet,
            chain_asset_handler,
            ctx.forge_args,
            ctx.l1_rpc_url.to_string(),
        )
        .await?;
    }

    Ok(())
}

pub async fn run(args: HubAcceptOwnershipArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = paths::path_from_root("l1-contracts");

    let (auth, sender, execution_mode) = resolve_execution(
        args.private_key,
        args.sender,
        args.dev,
        args.simulate,
        &args.l1_rpc_url,
    )?;

    let is_simulation = matches!(execution_mode, ExecutionMode::Simulate(_));
    let effective_rpc = execution_mode.rpc_url(&args.l1_rpc_url);

    if is_simulation {
        logger::info(format!(
            "Simulation mode: forking {} via anvil",
            args.l1_rpc_url
        ));
    }

    logger::info(format!("Accepting ownership for governor: {:#x}", sender));
    logger::info(format!("Governance contract: {:#x}", args.governance));
    logger::info(format!("Chain admin contract: {:#x}", args.chain_admin));

    let mut runner = ForgeRunner::new(args.forge_args.runner.clone());

    let input = AcceptOwnershipInput {
        bridgehub: args.bridgehub,
        asset_router: args.asset_router,
        stm_deployment_tracker: args.stm_deployment_tracker,
        chain_asset_handler: args.chain_asset_handler,
        governance: args.governance,
        chain_admin: args.chain_admin,
    };

    {
        let mut ctx = ForgeContext {
            shell,
            foundry_scripts_path: foundry_scripts_path.as_path(),
            runner: &mut runner,
            forge_args: &args.forge_args.script,
            l1_rpc_url: effective_rpc,
            auth: &auth,
        };
        accept_ownership(&mut ctx, &input).await?;
    }

    if is_simulation {
        logger::outro("Accept ownership simulation complete (no on-chain changes)");
    } else {
        logger::outro("Accept ownership complete");
    }

    drop(execution_mode);

    Ok(())
}
