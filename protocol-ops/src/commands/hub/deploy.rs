use crate::common::{forge::ForgeRunner, wallets::Wallet};
use crate::config::forge_interface::{
    deploy_ecosystem::{
        input::{DeployL1Config, InitialDeploymentConfig},
        output::DeployL1CoreContractsOutput,
    },
    script_params::DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS,
};
use ethers::types::{Address, H256};

/// Input parameters for deploying hub contracts.
#[derive(Debug, Clone)]
pub struct DeployInput {
    pub owner: Address,
    pub era_chain_id: u64,
    pub with_legacy_bridge: bool,
    pub create2_factory_addr: Option<Address>,
    pub create2_factory_salt: Option<H256>,
}

/// Deploy hub contracts and return the output.
pub fn deploy(
    runner: &mut ForgeRunner,
    auth: &Wallet,
    input: &DeployInput,
) -> anyhow::Result<DeployL1CoreContractsOutput> {
    let mut initial_config = InitialDeploymentConfig::default();

    if let Some(addr) = input.create2_factory_addr {
        initial_config.create2_factory_addr = Some(addr);
    }
    if let Some(salt) = input.create2_factory_salt {
        initial_config.create2_factory_salt = salt;
    }

    let deploy_config = DeployL1Config::new(
        input.owner,
        &initial_config,
        input.era_chain_id,
        input.with_legacy_bridge,
    );

    runner.run_script(
        &DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS,
        &deploy_config,
        auth,
    )
}
