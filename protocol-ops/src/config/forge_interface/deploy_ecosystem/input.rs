use std::str::FromStr;

use ethers::{
    types::{Address, H256, U256},
};
use serde::{Deserialize, Serialize};

use crate::common::traits::FileConfigTrait;

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct InitialDeploymentConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub create2_factory_addr: Option<Address>,
    pub create2_factory_salt: H256,
    pub governance_min_delay: u64,
    pub token_weth_address: Address,
    pub max_number_of_chains: u64,
    pub validator_timelock_execution_delay: u64,
    pub bridgehub_create_new_chain_salt: u64,
    pub gateway_settlement_fee: U256,
}

impl Default for InitialDeploymentConfig {
    fn default() -> Self {
        Self {
            create2_factory_addr: None,
            create2_factory_salt: H256::random(),
            governance_min_delay: 0,
            max_number_of_chains: 100,
            validator_timelock_execution_delay: 0,
            token_weth_address: Address::from_str("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")
                .unwrap(),
            bridgehub_create_new_chain_salt: 0,
            gateway_settlement_fee: U256::from(1000000000),
        }
    }
}

impl FileConfigTrait for InitialDeploymentConfig {}


#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DeployL1Config {
    pub era_chain_id: u64,
    pub owner_address: Address,
    pub support_l2_legacy_shared_bridge_test: bool,
    pub contracts: ContractsDeployL1Config,
    pub tokens: TokensDeployL1Config,
}

impl FileConfigTrait for DeployL1Config {}

impl DeployL1Config {
    pub fn new(
        owner_address: Address,
        initial_deployment_config: &InitialDeploymentConfig,
        era_chain_id: u64,
        support_l2_legacy_shared_bridge_test: bool,
    ) -> Self {
        Self {
            era_chain_id,
            owner_address,
            support_l2_legacy_shared_bridge_test,
            contracts: ContractsDeployL1Config {
                create2_factory_addr: initial_deployment_config.create2_factory_addr,
                create2_factory_salt: initial_deployment_config.create2_factory_salt,
                governance_security_council_address: owner_address,
                governance_min_delay: initial_deployment_config.governance_min_delay,
                max_number_of_chains: initial_deployment_config.max_number_of_chains,
                era_diamond_proxy_addr: None,
            },
            tokens: TokensDeployL1Config {
                token_weth_address: initial_deployment_config.token_weth_address,
            },
        }
    }
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ContractsDeployL1Config {
    pub governance_security_council_address: Address,
    pub governance_min_delay: u64,
    pub max_number_of_chains: u64,
    pub create2_factory_salt: H256,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub create2_factory_addr: Option<Address>,
    pub era_diamond_proxy_addr: Option<Address>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct TokensDeployL1Config {
    pub token_weth_address: Address,
}
