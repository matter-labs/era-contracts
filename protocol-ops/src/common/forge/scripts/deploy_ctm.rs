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
}

impl FileConfigTrait for DeployCTMConfig {}

impl DeployCTMConfig {
    pub fn new(
        owner_address: Address,
        initial_deployment_config: &InitialDeploymentConfig,
        testnet_verifier: bool,
        zk_token_asset_id: B256,
        support_l2_legacy_shared_bridge_test: bool,
        vm_option: VMOption,
    ) -> Self {
        Self {
            is_zk_sync_os: vm_option.is_zksync_os(),
            testnet_verifier,
            owner_address,
            support_l2_legacy_shared_bridge_test,
            zk_token_asset_id,
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
    pub genesis_upgrade_addr: Address,
    pub default_upgrade_addr: Address,
    pub bytecodes_supplier_addr: Address,
}
