use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};

use crate::common::traits::FileConfigTrait;
use crate::config::forge_interface::deploy_ecosystem::input::InitialDeploymentConfig;
use crate::types::VMOption;

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DeployCTMConfig {
    pub owner_address: Address,
    pub testnet_verifier: bool,
    pub support_l2_legacy_shared_bridge_test: bool,
    pub contracts: ContractsDeployCTMConfig,
    pub is_zk_sync_os: bool,
    pub zk_token_asset_id: H256,
}

impl FileConfigTrait for DeployCTMConfig {}

impl DeployCTMConfig {
    pub fn new(
        owner_address: Address,
        initial_deployment_config: &InitialDeploymentConfig,
        testnet_verifier: bool,
        zk_token_asset_id: H256,
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
    pub create2_factory_salt: H256,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub create2_factory_addr: Option<Address>,
    pub governance_security_council_address: Address,
    pub governance_min_delay: u64,
    pub validator_timelock_execution_delay: u64,
}
