use clap::Parser;
use ethers::types::{Address, H256};
use crate::common::{
    forge::{ForgeRunner, ForgeScriptArgs},
    logger,
    wallets::Wallet,
};
use serde::{Deserialize, Serialize};

use crate::admin_functions::{accept_admin, accept_owner};

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

    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeScriptArgs,
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
    runner: &mut ForgeRunner,
    auth: &Wallet,
    input: &CtmAcceptOwnershipInput,
) -> anyhow::Result<()> {
    logger::step("Accepting ownership of CTM...");
    accept_owner(runner, input.governance, auth, input.ctm_proxy).await?;

    logger::step("Accepting admin of CTM...");
    accept_admin(runner, input.chain_admin, auth, input.ctm_proxy).await?;

    Ok(())
}

pub async fn run(args: CtmAcceptOwnershipArgs) -> anyhow::Result<()> {
    let governor = Wallet::parse(args.private_key, args.sender)?;
    let mut runner = ForgeRunner::new(args.simulate, &args.l1_rpc_url, args.forge_args.clone())?;

    logger::info(format!("Accepting ownership for governor: {:#x}", governor.address));
    logger::info(format!("CTM proxy: {:#x}", args.ctm_proxy));
    logger::info(format!("Governance contract: {:#x}", args.governance));
    logger::info(format!("Chain admin contract: {:#x}", args.chain_admin));

    let input = CtmAcceptOwnershipInput {
        ctm_proxy: args.ctm_proxy,
        governance: args.governance,
        chain_admin: args.chain_admin,
    };

    accept_ownership(&mut runner, &governor, &input).await?;

    logger::outro("CTM accept ownership complete");

    Ok(())
}
