use alloy::primitives::{Address, B256};
use serde::{Deserialize, Serialize};

use crate::common::traits::FileConfigTrait;
use crate::types::VMOption;

use super::deploy_ecosystem::InitialDeploymentConfig;

pub use super::DEPLOY_CTM_INVOCATION as DEPLOY_CTM_SCRIPT_PARAMS;

pub use super::REGISTER_CTM_INVOCATION as REGISTER_CTM_SCRIPT_PARAMS;

// ── Input types ──────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DeployCTMConfig {
    pub owner_address: Address,
    pub testnet_verifier: bool,
    pub support_l2_legacy_shared_bridge_test: bool,
    pub contracts: ContractsDeployCTMConfig,
    pub is_zk_sync_os: bool,
    pub zk_token_asset_id: B256,
    pub multi_proof_verifier: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub zisk_plonk_verifier_addr: Option<Address>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub zisk_range_verifier_addr: Option<Address>,
}

impl FileConfigTrait for DeployCTMConfig {}

#[derive(Debug, Clone, Copy, Default)]
pub struct MultiProofDeployCTMConfig {
    pub enabled: bool,
    pub zisk_plonk_verifier_addr: Option<Address>,
    pub zisk_range_verifier_addr: Option<Address>,
}

impl DeployCTMConfig {
    pub fn new(
        owner_address: Address,
        initial_deployment_config: &InitialDeploymentConfig,
        testnet_verifier: bool,
        zk_token_asset_id: B256,
        support_l2_legacy_shared_bridge_test: bool,
        vm_option: VMOption,
        multi_proof: MultiProofDeployCTMConfig,
    ) -> Self {
        Self {
            is_zk_sync_os: vm_option.is_zksync_os(),
            testnet_verifier,
            owner_address,
            support_l2_legacy_shared_bridge_test,
            zk_token_asset_id,
            multi_proof_verifier: multi_proof.enabled,
            zisk_plonk_verifier_addr: multi_proof.zisk_plonk_verifier_addr,
            zisk_range_verifier_addr: multi_proof.zisk_range_verifier_addr,
            contracts: ContractsDeployCTMConfig {
                create2_factory_addr: initial_deployment_config.create2_factory_addr,
                create2_factory_salt: initial_deployment_config.create2_factory_salt,
                governance_security_council_address: owner_address,
                governance_min_delay: initial_deployment_config.governance_min_delay,
                validator_timelock_execution_delay: initial_deployment_config
                    .validator_timelock_execution_delay,
            },
        }
    }
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ContractsDeployCTMConfig {
    pub create2_factory_salt: B256,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub create2_factory_addr: Option<Address>,
    pub governance_security_council_address: Address,
    pub governance_min_delay: u64,
    pub validator_timelock_execution_delay: u64,
}

// ── Output types ─────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DeployCTMOutput {
    pub contracts_config: DeployCTMContractsConfigOutput,
    pub deployed_addresses: DeployCTMDeployedAddressesOutput,
    pub multicall3_addr: Address,
}

impl FileConfigTrait for DeployCTMOutput {}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DeployCTMDeployedAddressesOutput {
    pub governance_addr: Address,
    pub transparent_proxy_admin_addr: Address,
    pub validator_timelock_addr: Address,
    pub chain_admin: Address,
    pub state_transition: L1StateTransitionOutput,
    pub rollup_l1_da_validator_addr: Address,
    pub no_da_validium_l1_validator_addr: Address,
    pub avail_l1_da_validator_addr: Address,
    pub l1_rollup_da_manager: Address,
    pub blobs_zksync_os_l1_da_validator_addr: Option<Address>,
    pub server_notifier_proxy_addr: Address,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DeployCTMContractsConfigOutput {
    pub diamond_cut_data: String,
    pub force_deployments_data: Option<String>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct L1StateTransitionOutput {
    pub state_transition_proxy_addr: Address,
    pub verifier_addr: Address,
    pub airbender_verifier_addr: Option<Address>,
    pub zisk_verifier_addr: Option<Address>,
    pub zisk_testnet_verifier_addr: Option<Address>,
    pub multi_proof_verifier_addr: Option<Address>,
    pub genesis_upgrade_addr: Address,
    pub default_upgrade_addr: Address,
    pub bytecodes_supplier_addr: Address,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multiprover_fields_are_serialized_for_the_solidity_script() {
        let plonk = Address::repeat_byte(0x11);
        let range = Address::repeat_byte(0x22);
        let config = DeployCTMConfig::new(
            Address::repeat_byte(0x33),
            &InitialDeploymentConfig::default(),
            true,
            B256::repeat_byte(0x44),
            false,
            VMOption::ZKSyncOsVM,
            MultiProofDeployCTMConfig {
                enabled: true,
                zisk_plonk_verifier_addr: Some(plonk),
                zisk_range_verifier_addr: Some(range),
            },
        );

        let serialized = toml::to_string(&config).unwrap();

        assert!(serialized.contains("multi_proof_verifier = true"));
        assert!(serialized.contains(&format!("zisk_plonk_verifier_addr = \"{plonk}\"")));
        assert!(serialized.contains(&format!("zisk_range_verifier_addr = \"{range}\"")));
    }

    #[test]
    fn optional_multiprover_addresses_are_omitted() {
        let config = DeployCTMConfig::new(
            Address::repeat_byte(0x33),
            &InitialDeploymentConfig::default(),
            true,
            B256::repeat_byte(0x44),
            false,
            VMOption::ZKSyncOsVM,
            MultiProofDeployCTMConfig::default(),
        );

        let serialized = toml::to_string(&config).unwrap();

        assert!(serialized.contains("multi_proof_verifier = false"));
        assert!(!serialized.contains("zisk_plonk_verifier_addr"));
        assert!(!serialized.contains("zisk_range_verifier_addr"));
    }
}
