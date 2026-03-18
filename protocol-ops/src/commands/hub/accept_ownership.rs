use ethers::types::Address;
use crate::common::{
    forge::ForgeRunner,
    logger,
    wallets::Wallet,
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
    runner: &mut ForgeRunner,
    auth: &Wallet,
    input: &AcceptOwnershipInput,
) -> anyhow::Result<()> {
    logger::step("Accepting ownership of Bridgehub admin...");
    accept_admin(runner, input.chain_admin, auth, input.bridgehub).await?;

    logger::step("Accepting ownership of ecosystem governance contracts...");
    accept_owner_aggregated(runner, input.governance, auth, input.bridgehub).await?;

    Ok(())
}
