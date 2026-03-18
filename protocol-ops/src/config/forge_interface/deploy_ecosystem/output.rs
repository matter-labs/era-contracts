use ethers::types::Address;
use serde::{Deserialize, Serialize};

use crate::common::traits::FileConfigTrait;
use crate::config::forge_interface::Create2Addresses;

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DeployL1CoreContractsOutput {
    pub contracts: Create2Addresses,
    pub deployer_addr: Address,
    pub era_chain_id: u32,
    pub l1_chain_id: u32,
    pub owner_address: Address,
    pub deployed_addresses: DeployL1CoreContractsDeployedAddressesOutput,
}

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

impl FileConfigTrait for DeployL1CoreContractsOutput {}

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

