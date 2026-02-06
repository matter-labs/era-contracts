use ethers::types::{Address, U256};
use serde::{Deserialize, Serialize};
use protocol_ops_types::{L2ChainId, DAValidatorType};

use crate::{
    forge_interface::register_chain::input::NewChainParams,
    traits::FileConfigTrait,
    ContractsConfig
};

impl FileConfigTrait for DeployL2ContractsInput {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeployL2ContractsInput {
    pub era_chain_id: L2ChainId,
    pub chain_id: L2ChainId,
    pub l1_shared_bridge: Address,
    pub bridgehub: Address,
    pub governance: Address,
    pub erc20_bridge: Address,
    pub da_validator_type: U256,
    pub consensus_registry_owner: Address,
}

impl DeployL2ContractsInput {
    pub fn new(
        chain_params: &NewChainParams,
        chain_contracts: &ContractsConfig,
        ecosystem_owner: Address,
        era_chain_id: L2ChainId,
    ) -> anyhow::Result<Self> {
        Ok(Self {
            era_chain_id,
            chain_id: chain_params.chain_id,
            l1_shared_bridge: chain_contracts.bridges.shared.l1_address,
            bridgehub: chain_contracts.ecosystem_contracts.bridgehub_proxy_addr,
            governance: chain_contracts.l1.governance_addr,
            erc20_bridge: chain_contracts.bridges.erc20.l1_address,
            da_validator_type: U256::from(chain_params.da_mode.to_u8()),
            consensus_registry_owner: ecosystem_owner,
        })
    }
}
