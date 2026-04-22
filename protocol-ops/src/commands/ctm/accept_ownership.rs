use crate::admin_functions::{accept_admin, accept_owner};
use crate::common::{forge::ForgeRunner, wallets::Wallet};
use ethers::types::Address;

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
    // Accept governance ownership of CTM contracts
    accept_owner(runner, input.governance, auth, input.ctm_proxy).await?;

    // Accept admin ownership of CTM contracts
    accept_admin(runner, input.chain_admin, auth, input.ctm_proxy).await?;

    Ok(())
}
