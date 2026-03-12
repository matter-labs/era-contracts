use ethers::{contract::BaseContract, types::Address};
use lazy_static::lazy_static;
use crate::common::{
    forge::{Forge, ForgeContext, SenderAuth},
    logger,
    traits::ReadConfig,
};
use crate::config::{
    forge_interface::script_params::REGISTER_CTM_SCRIPT_PARAMS,
};

use crate::abi::IREGISTERCTMABI_ABI;
use crate::admin_functions::AdminScriptOutputInner;

lazy_static! {
    static ref REGISTER_CTM_FUNCTIONS: BaseContract = BaseContract::from(IREGISTERCTMABI_ABI.clone());
}

/// Input parameters for registering a CTM on the bridgehub.
#[derive(Debug, Clone)]
pub struct RegisterCtmInput {
    pub bridgehub: Address,
    pub ctm_proxy: Address,
}

/// Output from registering a CTM.
#[derive(Debug, Clone)]
pub struct RegisterCtmOutput {
    pub _admin_script_output: AdminScriptOutputInner,
}

/// Register a CTM on the bridgehub.
pub fn register_ctm(ctx: &mut ForgeContext, input: &RegisterCtmInput) -> anyhow::Result<RegisterCtmOutput> {
    // Encode calldata for registerCTM
    // The third parameter (broadcast) is always true when we're running via ForgeContext
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

    // Read output
    let output_path = REGISTER_CTM_SCRIPT_PARAMS.output(ctx.foundry_scripts_path);
    let admin_script_output = AdminScriptOutputInner::read(ctx.shell, output_path)?;

    Ok(RegisterCtmOutput { _admin_script_output: admin_script_output })
}