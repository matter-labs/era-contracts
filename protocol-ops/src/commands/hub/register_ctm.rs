use crate::common::abi::IRegisterCTMAbi;
use crate::common::forge::scripts::deploy_ctm::REGISTER_CTM_SCRIPT_PARAMS;
use crate::common::{
    forge::{Forge, ForgeRunner},
    logger,
    wallets::Wallet,
};
use alloy::primitives::Address;
use alloy::sol_types::SolCall;

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
    let calldata = IRegisterCTMAbi::registerCTMCall {
        bridgehub: input.bridgehub,
        chainTypeManagerProxy: input.ctm_proxy,
        shouldSend: true,
    }
    .abi_encode()
    .into();

    let forge = Forge::new(&runner.foundry_scripts_path)
        .script(
            &REGISTER_CTM_SCRIPT_PARAMS.script(),
            runner.forge_args.clone(),
        )
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(runner.rpc_url.clone())
        .with_broadcast()
        .with_wallet(auth);

    logger::info("Registering CTM on Bridgehub...");
    runner.run(forge)?;

    Ok(())
}
