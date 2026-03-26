use ethers::{
    contract::BaseContract,
    types::{Address, H256},
};
use lazy_static::lazy_static;
use serde::Serialize;

use crate::abi::IDEPLOYCTMABI_ABI;
use crate::common::{
    forge::{Forge, ForgeRunner},
    traits::{ReadConfig, SaveConfig},
    wallets::Wallet,
};
use crate::config::{
    forge_interface::{
        deploy_ctm::{input::DeployCTMConfig, output::DeployCTMOutput},
        deploy_ecosystem::input::InitialDeploymentConfig,
        permanent_values::PermanentValuesConfig,
        script_params::DEPLOY_CTM_SCRIPT_PARAMS,
    },
};
use crate::types::{L1Network, VMOption};

lazy_static! {
    static ref DEPLOY_CTM_FUNCTIONS: BaseContract = BaseContract::from(IDEPLOYCTMABI_ABI.clone());
}

/// Input parameters for deploying CTM contracts.
#[derive(Debug, Clone, Serialize)]
pub struct CtmDeployInput {
    pub bridgehub: Address,
    pub owner: Address,
    pub vm_type: VMOption,
    pub reuse_gov_and_admin: bool,
    pub with_testnet_verifier: bool,
    pub with_legacy_bridge: bool,
    pub create2_factory_addr: Option<Address>,
    pub create2_factory_salt: Option<H256>,
}

/// Deploy CTM contracts.
pub fn deploy(runner: &mut ForgeRunner, auth: &Wallet, input: &CtmDeployInput) -> anyhow::Result<DeployCTMOutput> {
    let l1_network = L1Network::from_l1_rpc(&runner.rpc_url)?;
    let mut initial_deployment_config = InitialDeploymentConfig::default();

    if let Some(addr) = input.create2_factory_addr {
        initial_deployment_config.create2_factory_addr = Some(addr);
    }
    if let Some(salt) = input.create2_factory_salt {
        initial_deployment_config.create2_factory_salt = salt;
    }

    let permanent_values = PermanentValuesConfig::new(
        initial_deployment_config.create2_factory_addr,
        initial_deployment_config.create2_factory_salt,
    );
    permanent_values.save(&runner.shell, PermanentValuesConfig::path(&runner.foundry_scripts_path))?;

    let deploy_config = DeployCTMConfig::new(
        input.owner,
        &initial_deployment_config,
        input.with_testnet_verifier,
        l1_network,
        input.with_legacy_bridge,
        input.vm_type,
    );

    let input_path = DEPLOY_CTM_SCRIPT_PARAMS.input(&runner.foundry_scripts_path);
    deploy_config.save(&runner.shell, input_path)?;

    let calldata = DEPLOY_CTM_FUNCTIONS
        .encode("runWithBridgehub", (input.bridgehub, input.reuse_gov_and_admin))
        .map_err(|e| anyhow::anyhow!("Failed to encode calldata: {}", e))?;

    let forge = Forge::new(&runner.foundry_scripts_path)
        .script(&DEPLOY_CTM_SCRIPT_PARAMS.script(), runner.forge_args.clone())
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(runner.rpc_url.clone())
        .with_broadcast()
        .with_slow()
        .with_wallet(auth, runner.simulate);

    runner.run(forge)?;

    let output_path = DEPLOY_CTM_SCRIPT_PARAMS.output(&runner.foundry_scripts_path);
    DeployCTMOutput::read(&runner.shell, output_path)
}
