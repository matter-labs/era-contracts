use crate::common::{forge::ForgeRunner, logger, wallets::Wallet};
use crate::config::forge_interface::script_params::REGISTER_CTM_INVOCATION;
use ethers::types::Address;

/// Input parameters for registering a CTM on the bridgehub.
#[derive(Debug, Clone)]
pub struct RegisterCtmInput {
    pub bridgehub: Address,
    pub ctm_proxy: Address,
}

/// Register a CTM on the bridgehub.
pub fn register_ctm(
    runner: &mut ForgeRunner,
    auth: &Wallet,
    input: &RegisterCtmInput,
) -> anyhow::Result<()> {
    let forge = runner
        .with_script_call(
            &REGISTER_CTM_INVOCATION,
            "registerCTM",
            (input.bridgehub, input.ctm_proxy, true),
        )?
        .with_wallet(auth);

    logger::info("Registering CTM on Bridgehub...");
    runner.run(forge)?;

    Ok(())
}
