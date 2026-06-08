use crate::common::admin_functions::{accept_admin, accept_owner_aggregated};
use crate::common::{forge::ForgeRunner, logger, wallets::Wallet};
use alloy::primitives::Address;

/// Input parameters for accepting ownership of hub contracts.
#[derive(Debug, Clone)]
pub struct AcceptOwnershipInput {
    pub bridgehub: Address,
    pub governance: Address,
    pub chain_admin: Address,
}

/// Accept ownership of hub contracts.
///
/// Both steps use forge broadcast so the transactions are applied to the fork
/// immediately and captured in `runner.runs()` for Safe bundle generation.
/// This ensures subsequent forge scripts in the same session (e.g. CTM deploy)
/// see the updated `bridgehub.admin()` and `bridgehub.owner()` values.
pub async fn accept_ownership(
    runner: &mut ForgeRunner,
    auth: &Wallet,
    input: &AcceptOwnershipInput,
) -> anyhow::Result<()> {
    // Accept chain-admin ownership via forge broadcast.
    // Broadcasts `deployer → ChainAdminOwnable.multicall([bridgehub.acceptAdmin()])`,
    // setting bridgehub.admin() = ChainAdminOwnable on the fork.
    let t = std::time::Instant::now();
    accept_admin(runner, input.chain_admin, auth, input.bridgehub)?;
    logger::info(format!("[timing] hub.accept_admin: {:.2?}", t.elapsed()));

    // Accept governance ownership via forge broadcast.
    let t = std::time::Instant::now();
    accept_owner_aggregated(runner, input.governance, auth, input.bridgehub)?;
    logger::info(format!(
        "[timing] hub.accept_owner_aggregated: {:.2?}",
        t.elapsed()
    ));

    Ok(())
}
