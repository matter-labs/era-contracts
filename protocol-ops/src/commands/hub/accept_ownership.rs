use ethers::types::Address;
use crate::common::{
    forge::ForgeContext,
    logger,
};

use crate::admin_functions::{accept_admin, accept_owner_aggregated};


/// Input parameters for accepting ownership of hub contracts.
#[derive(Debug, Clone)]
pub struct AcceptOwnershipInput {
    pub bridgehub: Address,
    pub governance: Address,
    pub chain_admin: Address,
}

/// Accept ownership of hub contracts.
pub async fn accept_ownership(
    ctx: &mut ForgeContext<'_>,
    input: &AcceptOwnershipInput,
) -> anyhow::Result<()> {
    let governor_wallet = ctx.auth.to_wallet()?;

    logger::step("Accepting ownership of Bridgehub admin...");
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

    logger::step("Accepting ownership of ecosystem governance contracts...");
    accept_owner_aggregated(
        ctx.shell,
        ctx.runner,
        ctx.foundry_scripts_path,
        input.governance,
        &governor_wallet,
        input.bridgehub,
        &ctx.forge_args,
        ctx.l1_rpc_url.to_string(),
    )
    .await?;

    Ok(())
}
