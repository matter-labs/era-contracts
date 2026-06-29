use alloy::primitives::{Address, B256};
use anyhow::bail;
use serde::Serialize;

use crate::common::abi::IDeployCTMAbi;
use crate::common::forge::scripts::{
    deploy_ctm::{DeployCTMConfig, DeployCTMOutput},
    deploy_ecosystem::InitialDeploymentConfig,
    DEPLOY_CTM_INVOCATION,
};
use crate::common::{
    forge::ForgeRunner,
    traits::{ReadConfig, SaveConfig},
    wallets::Wallet,
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
    pub zk_token_asset_id: Option<B256>,
    pub create2_factory_salt: Option<B256>,
}

/// Deploy CTM contracts.
pub fn deploy(
    runner: &mut ForgeRunner,
    auth: &Wallet,
    input: &CtmDeployInput,
) -> anyhow::Result<DeployCTMOutput> {
    let l1_network = L1Network::from_l1_rpc(&runner.rpc_url)?;
    ensure_testnet_verifier_allowed(l1_network, input.with_testnet_verifier)?;
    let mut initial_deployment_config = InitialDeploymentConfig::default();

    // CREATE2 factory address isn't configurable: the Solidity script
    // unconditionally uses `Utils.DETERMINISTIC_CREATE2_ADDRESS`
    // (0x4e59b4…c, an EVM-wide constant).
    if let Some(salt) = input.create2_factory_salt {
        initial_deployment_config.create2_factory_salt = salt;
    }
    let zk_token_asset_id = input
        .zk_token_asset_id
        .map(Ok)
        .unwrap_or_else(|| l1_network.zk_token_asset_id())?;

    let deploy_config = DeployCTMConfig::new(
        input.owner,
        &initial_deployment_config,
        input.with_testnet_verifier,
        zk_token_asset_id,
        input.with_legacy_bridge,
        input.vm_type,
    );

    let input_path = runner.input_path(&DEPLOY_CTM_INVOCATION)?;
    deploy_config.save(input_path)?;

    // protocol-ops always states the script's IO paths explicitly (the
    // conventional ones unless a per-run --subdir is set); `runWithBridgehub`
    // with its baked-in paths is for manual forge use.
    let forge = runner
        .script_call(IDeployCTMAbi::runInnerCall {
            inputPath: runner.script_rel_path(DEPLOY_CTM_INVOCATION.input_rel()),
            outputPath: runner.script_rel_path(DEPLOY_CTM_INVOCATION.output_rel()),
            bridgehub: input.bridgehub,
            reuseGovAndAdmin: input.reuse_gov_and_admin,
            skipL1Deployments: false,
        })
        .with_wallet(auth)
        .with_env(
            "CREATE2_FACTORY_SALT",
            format!("{:#x}", initial_deployment_config.create2_factory_salt),
        );

    runner.run(forge)?;

    let output_path = runner.output_path(&DEPLOY_CTM_INVOCATION);
    DeployCTMOutput::read(output_path)
}

fn ensure_testnet_verifier_allowed(
    l1_network: L1Network,
    with_testnet_verifier: bool,
) -> anyhow::Result<()> {
    if with_testnet_verifier && matches!(l1_network, L1Network::Mainnet) {
        bail!(
            "--with-testnet-verifier cannot be used on mainnet. \
             Testnet verifier constructors intentionally reject mainnet, and \
             spoofing the simulation chain id would generate calldata for the wrong L1."
        );
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_testnet_verifier_on_mainnet() {
        let err = ensure_testnet_verifier_allowed(L1Network::Mainnet, true).unwrap_err();

        assert!(err.to_string().contains("--with-testnet-verifier"));
    }

    #[test]
    fn allows_real_verifier_on_mainnet() {
        ensure_testnet_verifier_allowed(L1Network::Mainnet, false).unwrap();
    }

    #[test]
    fn allows_testnet_verifier_off_mainnet() {
        ensure_testnet_verifier_allowed(L1Network::Sepolia, true).unwrap();
        ensure_testnet_verifier_allowed(L1Network::Holesky, true).unwrap();
        ensure_testnet_verifier_allowed(L1Network::Localhost, true).unwrap();
    }
}
