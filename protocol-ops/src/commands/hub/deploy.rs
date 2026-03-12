use ethers::types::{Address, H256};
use crate::common::{
    forge::ForgeContext,
    logger,
    traits::SaveConfig,
};
use crate::config::{
    forge_interface::{
        deploy_ecosystem::{
            input::{DeployL1Config, InitialDeploymentConfig},
            output::DeployL1CoreContractsOutput,
        },
        permanent_values::PermanentValuesConfig,
        script_params::DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS,
    },
};

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
pub fn deploy(ctx: &mut ForgeContext, input: &DeployInput) -> anyhow::Result<DeployL1CoreContractsOutput> {
    let mut initial_config = InitialDeploymentConfig::default();

    // Override create2 factory settings if provided
    if let Some(addr) = input.create2_factory_addr {
        initial_config.create2_factory_addr = Some(addr);
    }
    if let Some(salt) = input.create2_factory_salt {
        initial_config.create2_factory_salt = salt;
    }

    // Update permanent-values.toml so Forge scripts use the correct factory
    let permanent_values = PermanentValuesConfig::new(
        initial_config.create2_factory_addr,
        initial_config.create2_factory_salt,
    );
    permanent_values.save(ctx.shell, PermanentValuesConfig::path(ctx.foundry_scripts_path))?;

    let deploy_config = DeployL1Config::new(
        input.owner,
        &initial_config,
        input.era_chain_id,
        input.with_legacy_bridge,
    );

    logger::info("Deploying hub contracts...");
    ctx.run(&DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS, &deploy_config)
}
