use alloy::primitives::{Address, B256};
use anyhow::bail;
use serde::Serialize;

use crate::common::abi::IDeployCTMAbi;
use crate::common::forge::scripts::{
    deploy_ctm::{DeployCTMConfig, DeployCTMOutput, MultiProofDeployCTMConfig},
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
    pub zk_token_asset_id: Option<B256>,
    pub create2_factory_salt: Option<B256>,
    pub multi_proof_verifier: bool,
    pub zisk_plonk_verifier_addr: Option<Address>,
    pub zisk_range_verifier_addr: Option<Address>,
}

/// Deploy CTM contracts.
pub fn deploy(
    runner: &mut ForgeRunner,
    auth: &Wallet,
    input: &CtmDeployInput,
) -> anyhow::Result<DeployCTMOutput> {
    let l1_network = L1Network::from_l1_rpc(&runner.rpc_url)?;
    ensure_testnet_verifier_allowed(l1_network, input.with_testnet_verifier)?;
    ensure_multi_proof_config(
        input.vm_type,
        input.multi_proof_verifier,
        input.zisk_plonk_verifier_addr,
        input.zisk_range_verifier_addr,
    )?;
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
        // The legacy shared-bridge test support this gated was removed.
        false,
        input.vm_type,
        MultiProofDeployCTMConfig {
            enabled: input.multi_proof_verifier,
            zisk_plonk_verifier_addr: input.zisk_plonk_verifier_addr,
            zisk_range_verifier_addr: input.zisk_range_verifier_addr,
        },
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

fn ensure_multi_proof_config(
    vm_type: VMOption,
    multi_proof_verifier: bool,
    zisk_plonk_verifier_addr: Option<Address>,
    zisk_range_verifier_addr: Option<Address>,
) -> anyhow::Result<()> {
    if !multi_proof_verifier {
        if zisk_plonk_verifier_addr.is_some() || zisk_range_verifier_addr.is_some() {
            bail!("ZiSK verifier addresses require multi_proof_verifier=true");
        }
        return Ok(());
    }

    if !vm_type.is_zksync_os() {
        bail!("multi_proof_verifier is supported only by the ZKsync OS VM");
    }
    if zisk_plonk_verifier_addr.is_none_or(|address| address == Address::ZERO) {
        bail!("multi_proof_verifier requires a non-zero zisk_plonk_verifier_addr");
    }
    if zisk_range_verifier_addr.is_some_and(|address| address == Address::ZERO) {
        bail!("zisk_range_verifier_addr must be non-zero when supplied");
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

    #[test]
    fn accepts_complete_zksync_os_multiprover_config() {
        ensure_multi_proof_config(
            VMOption::ZKSyncOsVM,
            true,
            Some(Address::repeat_byte(0x11)),
            None,
        )
        .unwrap();
    }

    #[test]
    fn requires_plonk_verifier_for_multiprover() {
        let err = ensure_multi_proof_config(VMOption::ZKSyncOsVM, true, None, None).unwrap_err();

        assert!(err.to_string().contains("zisk_plonk_verifier_addr"));
    }

    #[test]
    fn rejects_multiprover_for_era_vm() {
        let err = ensure_multi_proof_config(
            VMOption::EraVM,
            true,
            Some(Address::repeat_byte(0x11)),
            None,
        )
        .unwrap_err();

        assert!(err.to_string().contains("ZKsync OS"));
    }
}
