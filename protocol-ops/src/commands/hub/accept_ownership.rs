use crate::common::{forge::ForgeRunner, logger, wallets::Wallet};
use ethers::types::Address;

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
    // Accept admin ownership of Bridgehub contracts
    let t = std::time::Instant::now();
    accept_admin(runner, input.chain_admin, auth, input.bridgehub).await?;
    logger::info(format!("[timing] hub.accept_admin: {:.2?}", t.elapsed()));

    // Accept governance ownership of Bridgehub contracts
    let t = std::time::Instant::now();
    accept_owner_aggregated(runner, input.governance, auth, input.bridgehub).await?;
    logger::info(format!(
        "[timing] hub.accept_owner_aggregated: {:.2?}",
        t.elapsed()
    ));

    Ok(())
}
