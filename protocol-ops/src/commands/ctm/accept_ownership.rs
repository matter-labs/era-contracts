use crate::common::admin_functions::{accept_admin, accept_owner};
use crate::common::{forge::ForgeRunner, logger, wallets::Wallet};
use alloy::primitives::Address;

/// Input parameters for accepting ownership of CTM contracts.
#[derive(Debug, Clone)]
pub struct CtmAcceptOwnershipInput {
    pub ctm_proxy: Address,
    pub governance: Address,
    pub chain_admin: Address,
}

/// Accept ownership of CTM contracts via forge broadcast.
///
/// Both `accept_owner` and `accept_admin` use forge broadcast so the
/// transactions are applied to the fork immediately and captured in
/// `runner.runs()` for Safe bundle generation.
pub async fn accept_ownership(
    runner: &mut ForgeRunner,
    auth: &Wallet,
    input: &CtmAcceptOwnershipInput,
) -> anyhow::Result<()> {
    // Accept governance ownership via forge broadcast.
    let t = std::time::Instant::now();
    accept_owner(runner, input.governance, auth, input.ctm_proxy)?;
    logger::info(format!("[timing] ctm.accept_owner: {:.2?}", t.elapsed()));

    // Accept chain-admin ownership via forge broadcast.
    // Broadcasts `deployer → ChainAdminOwnable.multicall([ctm.acceptAdmin()])`,
    // setting ctm.admin() = ChainAdminOwnable on the fork.
    let t = std::time::Instant::now();
    accept_admin(runner, input.chain_admin, auth, input.ctm_proxy)?;
    logger::info(format!("[timing] ctm.accept_admin: {:.2?}", t.elapsed()));

    Ok(())
}
