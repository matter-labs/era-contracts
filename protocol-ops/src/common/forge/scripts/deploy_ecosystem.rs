use std::str::FromStr;

use alloy::primitives::{Address, B256};
use serde::{Deserialize, Serialize};

use crate::common::addresses::MAINNET_WETH_ADDRESS;
use crate::common::forge::scripts::Create2Addresses;
use crate::common::traits::FileConfigTrait;

pub use super::DEPLOY_ECOSYSTEM_CORE_CONTRACTS_INVOCATION as DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS;

// ── Input types ──────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct InitialDeploymentConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub create2_factory_addr: Option<Address>,
    pub create2_factory_salt: B256,
    pub governance_min_delay: u64,
    pub token_weth_address: Address,
    pub max_number_of_chains: u64,
    pub validator_timelock_execution_delay: u64,
    pub bridgehub_create_new_chain_salt: u64,
}

impl Default for InitialDeploymentConfig {
    fn default() -> Self {
        Self {
            create2_factory_addr: None,
            create2_factory_salt: B256::from(rand::random::<[u8; 32]>()),
            governance_min_delay: 0,
            max_number_of_chains: 100,
            validator_timelock_execution_delay: 0,
            token_weth_address: Address::from_str(MAINNET_WETH_ADDRESS).unwrap(),
            bridgehub_create_new_chain_salt: 0,
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
    pub create2_factory_salt: B256,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub create2_factory_addr: Option<Address>,
    pub era_diamond_proxy_addr: Option<Address>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct TokensDeployL1Config {
    pub token_weth_address: Address,
}

// ── Output types ─────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DeployL1CoreContractsOutput {
    pub contracts: Create2Addresses,
    pub deployer_addr: Address,
    pub era_chain_id: u32,
    pub l1_chain_id: u32,
    pub owner_address: Address,
    pub deployed_addresses: DeployL1CoreContractsDeployedAddressesOutput,
}

impl FileConfigTrait for DeployL1CoreContractsOutput {}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DeployL1CoreContractsDeployedAddressesOutput {
    pub governance_addr: Address,
    pub transparent_proxy_admin_addr: Address,
    pub chain_admin: Address,
    pub access_control_restriction_addr: Address,
    pub bridgehub: L1BridgehubOutput,
    pub bridges: L1BridgesOutput,
    pub native_token_vault_addr: Address,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct L1BridgehubOutput {
    pub bridgehub_implementation_addr: Address,
    pub bridgehub_proxy_addr: Address,
    pub ctm_deployment_tracker_proxy_addr: Address,
    pub ctm_deployment_tracker_implementation_addr: Address,
    pub message_root_proxy_addr: Address,
    pub message_root_implementation_addr: Address,
    pub chain_asset_handler_proxy_addr: Address,
    pub chain_asset_handler_implementation_addr: Address,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct L1BridgesOutput {
    pub erc20_bridge_implementation_addr: Address,
    pub erc20_bridge_proxy_addr: Address,
    pub shared_bridge_implementation_addr: Address,
    pub shared_bridge_proxy_addr: Address,
    pub l1_nullifier_implementation_addr: Address,
    pub l1_nullifier_proxy_addr: Address,
}
