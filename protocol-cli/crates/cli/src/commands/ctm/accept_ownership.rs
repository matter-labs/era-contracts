use clap::Parser;
use ethers::types::{Address, H256};
use protocol_cli_common::{
    forge::{ForgeArgs, ForgeRunner},
    logger,
};
use serde::{Deserialize, Serialize};
use xshell::Shell;

use crate::admin_functions::{accept_admin, accept_owner};
use crate::forge_ctx::{resolve_execution, ExecutionMode, ForgeContext};
use crate::utils::paths;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct CtmAcceptOwnershipArgs {
    /// CTM (State Transition Manager) proxy address
    #[clap(long)]
    pub ctm_proxy: Address,

    /// Governance contract address
    #[clap(long)]
    pub governance: Address,

    /// Chain admin contract address
    #[clap(long)]
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

/// Input parameters for accepting ownership of CTM contracts.
#[derive(Debug, Clone)]
pub struct CtmAcceptOwnershipInput {
    pub ctm_proxy: Address,
    pub governance: Address,
    pub chain_admin: Address,
}

/// Accept ownership of CTM contracts.
pub async fn accept_ownership(
    ctx: &mut ForgeContext<'_>,
    input: &CtmAcceptOwnershipInput,
) -> anyhow::Result<()> {
    let governor_wallet = ctx.auth.to_wallet()?;

    // Accept ownership for CTM (State Transition Manager)
    logger::step("Accepting ownership of CTM...");
    accept_owner(
        ctx.shell,
        ctx.runner,
        ctx.foundry_scripts_path,
        input.governance,
        &governor_wallet,
        input.ctm_proxy,
        ctx.forge_args,
        ctx.l1_rpc_url.to_string(),
    )
    .await?;

    logger::step("Accepting admin of CTM...");
    accept_admin(
        ctx.shell,
        ctx.runner,
        ctx.foundry_scripts_path,
        input.chain_admin,
        &governor_wallet,
        input.ctm_proxy,
        ctx.forge_args,
        ctx.l1_rpc_url.to_string(),
    )
    .await?;

    Ok(())
}

pub async fn run(args: CtmAcceptOwnershipArgs, shell: &Shell) -> anyhow::Result<()> {
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
    logger::info(format!("CTM proxy: {:#x}", args.ctm_proxy));
    logger::info(format!("Governance contract: {:#x}", args.governance));
    logger::info(format!("Chain admin contract: {:#x}", args.chain_admin));

    let mut runner = ForgeRunner::new(args.forge_args.runner.clone());

    let input = CtmAcceptOwnershipInput {
        ctm_proxy: args.ctm_proxy,
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
        logger::outro("CTM accept ownership simulation complete (no on-chain changes)");
    } else {
        logger::outro("CTM accept ownership complete");
    }

    drop(execution_mode);

    Ok(())
}
