use ethers::types::{Address, H256};
use serde::Serialize;

use crate::common::{
    forge::ForgeRunner,
    traits::{ReadConfig, SaveConfig},
    wallets::Wallet,
};
use crate::config::forge_interface::{
    deploy_ctm::{input::DeployCTMConfig, output::DeployCTMOutput},
    deploy_ecosystem::input::InitialDeploymentConfig,
    script_params::DEPLOY_CTM_INVOCATION,
};
use crate::types::{L1Network, VMOption};

/// Input parameters for deploying CTM contracts.
#[derive(Debug, Clone, Serialize)]
pub struct CtmDeployInput {
    pub bridgehub: Address,
    pub owner: Address,
    pub vm_type: VMOption,
    pub reuse_gov_and_admin: bool,
    pub with_testnet_verifier: bool,
    pub with_legacy_bridge: bool,
    pub zk_token_asset_id: Option<H256>,
    pub create2_factory_salt: Option<H256>,
}

/// Deploy CTM contracts.
pub fn deploy(
    runner: &mut ForgeRunner,
    auth: &Wallet,
    input: &CtmDeployInput,
) -> anyhow::Result<DeployCTMOutput> {
    let l1_network = L1Network::from_l1_rpc(&runner.rpc_url)?;
    let mut initial_deployment_config = InitialDeploymentConfig::default();

    // CREATE2 factory address isn't configurable: the Solidity script
    // unconditionally uses `Utils.DETERMINISTIC_CREATE2_ADDRESS`
    // (0x4e59b4…c, an EVM-wide constant).
    if let Some(salt) = input.create2_factory_salt {
        initial_deployment_config.create2_factory_salt = salt;
    }
    let zk_token_asset_id = input
        .zk_token_asset_id
        .unwrap_or(l1_network.zk_token_asset_id());

    let deploy_config = DeployCTMConfig::new(
        input.owner,
        &initial_deployment_config,
        input.with_testnet_verifier,
        zk_token_asset_id,
        input.with_legacy_bridge,
        input.vm_type,
    );

    let input_path = DEPLOY_CTM_INVOCATION.input(&runner.foundry_scripts_path);
    deploy_config.save(&runner.shell, input_path)?;

    let forge = runner
        .with_script_call(
            &DEPLOY_CTM_INVOCATION,
            "runWithBridgehub",
            (input.bridgehub, input.reuse_gov_and_admin),
        )?
        .with_wallet(auth)
        .with_env(
            "CREATE2_FACTORY_SALT",
            format!("{:#x}", initial_deployment_config.create2_factory_salt),
        );

    runner.run(forge)?;

    let output_path = DEPLOY_CTM_INVOCATION.output(&runner.foundry_scripts_path);
    DeployCTMOutput::read(&runner.shell, output_path)
}
