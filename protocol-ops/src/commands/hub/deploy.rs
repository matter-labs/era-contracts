use crate::common::{
    forge::ForgeContext,
    logger,
};
use crate::config::forge_interface::{
    deploy_ecosystem::{
        input::{DeployL1Config, InitialDeploymentConfig},
        output::DeployL1CoreContractsOutput,
    },
    script_params::DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS,
};
use ethers::types::Address;

/// Input parameters for deploying Bridgehub contracts.
#[derive(Debug, Clone)]
pub struct DeployInput {
    pub owner: Address,
    pub era_chain_id: u64,
    pub with_legacy_bridge: bool,
}

/// Deploy Bridgehub contracts
pub fn deploy(
    ctx: &mut ForgeContext,
    input: &DeployInput,
) -> anyhow::Result<DeployL1CoreContractsOutput> {
    let initial_config = InitialDeploymentConfig::default();

    let deploy_config = DeployL1Config::new(
        input.owner,
        &initial_config,
        input.era_chain_id,
        input.with_legacy_bridge,
    );

    logger::info("Deploying hub contracts...");
    ctx.run(
        &DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS,
        &deploy_config,
    )
}
