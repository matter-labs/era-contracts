use alloy::primitives::Address;
use alloy::sol_types::SolCall;

use crate::common::abi::IRegisterCTMAbi;
use crate::common::forge::scripts::REGISTER_CTM_INVOCATION;
use crate::common::{forge::ForgeRunner, logger, wallets::Wallet};

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
    // protocol-ops always states the script's IO paths explicitly (the
    // conventional ones unless a per-run --subdir is set); `registerCTM`
    // with its baked-in path is for manual forge use.
    let calldata = IRegisterCTMAbi::runInnerCall {
        outputPath: runner.script_rel_path(REGISTER_CTM_INVOCATION.output_rel()),
        bridgehub: input.bridgehub,
        chainTypeManagerProxy: input.ctm_proxy,
        shouldSend: true,
    }
    .abi_encode();
    let forge = runner
        .script_with_calldata(&REGISTER_CTM_INVOCATION, calldata)
        .with_wallet(auth);

    logger::info("Registering CTM on Bridgehub...");
    runner.run(forge)?;

    Ok(())
}
