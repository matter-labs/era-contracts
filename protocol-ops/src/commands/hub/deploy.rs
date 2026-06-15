use crate::common::abi::IDeployL1CoreContractsAbi;
use crate::common::forge::scripts::{
    deploy_ecosystem::{DeployL1Config, DeployL1CoreContractsOutput, InitialDeploymentConfig},
    DEPLOY_ECOSYSTEM_CORE_CONTRACTS_INVOCATION,
};
use crate::common::{
    forge::ForgeRunner,
    traits::{ReadConfig, SaveConfig},
    wallets::Wallet,
};
use alloy::primitives::{Address, B256};
use alloy::sol_types::SolCall;
use serde::Serialize;

/// Input parameters for deploying hub contracts.
#[derive(Debug, Clone, Serialize)]
pub struct DeployInput {
    pub owner: Address,
    pub era_chain_id: u64,
    pub with_legacy_bridge: bool,
    pub create2_factory_salt: Option<B256>,
}

/// Deploy hub contracts and return the output.
pub fn deploy(
    runner: &mut ForgeRunner,
    auth: &Wallet,
    input: &DeployInput,
) -> anyhow::Result<DeployL1CoreContractsOutput> {
    let mut initial_config = InitialDeploymentConfig::default();

    if let Some(salt) = input.create2_factory_salt {
        initial_config.create2_factory_salt = salt;
    }

    let deploy_config = DeployL1Config::new(
        input.owner,
        &initial_config,
        input.era_chain_id,
        input.with_legacy_bridge,
    );

    let input_path = runner.input_path(&DEPLOY_ECOSYSTEM_CORE_CONTRACTS_INVOCATION)?;
    deploy_config.save(&input_path)?;

    // protocol-ops always states the script's IO paths explicitly (the
    // conventional ones unless a per-run --subdir is set); the `run()`
    // wrapper with baked-in paths is for manual forge use.
    let forge = runner
        .script_with_calldata(
            &DEPLOY_ECOSYSTEM_CORE_CONTRACTS_INVOCATION,
            IDeployL1CoreContractsAbi::runInnerCall {
                inputPath: runner
                    .script_rel_path(DEPLOY_ECOSYSTEM_CORE_CONTRACTS_INVOCATION.input_rel()),
                outputPath: runner
                    .script_rel_path(DEPLOY_ECOSYSTEM_CORE_CONTRACTS_INVOCATION.output_rel()),
            }
            .abi_encode(),
        )
        .with_wallet(auth)
        .with_env(
            "CREATE2_FACTORY_SALT",
            format!("{:#x}", initial_config.create2_factory_salt),
        );

    runner.run(forge)?;

    let output_path = runner.output_path(&DEPLOY_ECOSYSTEM_CORE_CONTRACTS_INVOCATION);
    DeployL1CoreContractsOutput::read(output_path)
}
