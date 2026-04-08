use ethers::{contract::BaseContract, types::Address};
use lazy_static::lazy_static;
use crate::common::{
    forge::{Forge, ForgeRunner},
    logger,
    traits::ReadConfig,
    wallets::Wallet,
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
pub fn register_ctm(runner: &mut ForgeRunner, auth: &Wallet, input: &RegisterCtmInput) -> anyhow::Result<RegisterCtmOutput> {
    let calldata = REGISTER_CTM_FUNCTIONS
        .encode("registerCTM", (input.bridgehub, input.ctm_proxy, true))
        .map_err(|e| anyhow::anyhow!("Failed to encode calldata: {}", e))?;

    let forge = Forge::new(&runner.foundry_scripts_path)
        .script(&REGISTER_CTM_SCRIPT_PARAMS.script(), runner.forge_args.clone())
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(runner.rpc_url.clone())
        .with_broadcast()
        .with_slow()
        .with_wallet(auth, runner.simulate);

    logger::info("Registering CTM on Bridgehub...");
    runner.run(forge)?;

    let output_path = REGISTER_CTM_SCRIPT_PARAMS.output(&runner.foundry_scripts_path);
    let admin_script_output = AdminScriptOutputInner::read(&runner.shell, output_path)?;

    Ok(RegisterCtmOutput { _admin_script_output: admin_script_output })
}
