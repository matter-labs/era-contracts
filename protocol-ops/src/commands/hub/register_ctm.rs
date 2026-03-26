use crate::common::{
    forge::{Forge, ForgeContext, SenderAuth},
    logger,
};
use crate::config::{
    forge_interface::script_params::REGISTER_CTM_SCRIPT_PARAMS,
};
use ethers::{
    contract::BaseContract,
    types::Address,
};
use lazy_static::lazy_static;

use crate::abi::IREGISTERCTMABI_ABI;

lazy_static! {
    static ref REGISTER_CTM_FUNCTIONS: BaseContract =
        BaseContract::from(IREGISTERCTMABI_ABI.clone());
}

/// Input for register_ctm
#[derive(Debug, Clone)]
pub struct RegisterCtmInput {
    pub bridgehub: Address,
    pub ctm_proxy: Address,
}

/// Register a CTM on the bridgehub.
pub fn register_ctm(
    ctx: &mut ForgeContext,
    input: &RegisterCtmInput,
) -> anyhow::Result<()> {
    // Encode calldata for registerCTM
    let calldata = REGISTER_CTM_FUNCTIONS
        .encode("registerCTM", (input.bridgehub, input.ctm_proxy, true))
        .map_err(|e| anyhow::anyhow!("Failed to encode calldata: {}", e))?;

    // Build forge command
    let mut forge = Forge::new(ctx.foundry_scripts_path)
        .script(&REGISTER_CTM_SCRIPT_PARAMS.script(), ctx.forge_args.clone())
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(ctx.l1_rpc_url.to_string())
        .with_broadcast()
        .with_slow();

    match ctx.auth {
        SenderAuth::PrivateKey(pk) => {
            forge = forge.with_private_key(*pk);
        }
        SenderAuth::Unlocked(addr) => {
            forge = forge.with_sender(format!("{:#x}", addr)).with_unlocked();
        }
    }

    logger::info("Registering CTM on Bridgehub...");
    ctx.runner.run(ctx.shell, forge)?;
   
    Ok(())
}
