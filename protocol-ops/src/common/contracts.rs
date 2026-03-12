use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};

use crate::common::traits::FileConfigTrait;

// Contracts related to ecosystem, without chain specifics
#[derive(Debug, Deserialize, Serialize, Clone, Default)]
pub struct CoreContractsConfig {
    pub create2_factory_addr: Address,
    pub create2_factory_salt: H256,
    pub multicall3_addr: Address,
    pub core_ecosystem_contracts: CoreEcosystemContracts,
    pub bridges: BridgesContracts,
    pub l1: L1CoreContracts,
    pub era_ctm: Option<ChainTransitionManagerContracts>,
    pub zksync_os_ctm: Option<ChainTransitionManagerContracts>,
    pub proof_manager_contracts: Option<EthProofManagerContracts>,
}

impl FileConfigTrait for CoreContractsConfig {}

#[derive(Debug, Deserialize, Serialize, Clone, Default)]
pub struct ContractsConfigForDeployERC20 {
    pub create2_factory_addr: Address,
    pub create2_factory_salt: H256,
}

impl From<CoreContractsConfig> for ContractsConfigForDeployERC20 {
    fn from(config: CoreContractsConfig) -> Self {
        ContractsConfigForDeployERC20 {
            create2_factory_addr: config.create2_factory_addr,
            create2_factory_salt: config.create2_factory_salt,
        }
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Default)]
pub struct CoreEcosystemContracts {
    pub bridgehub_proxy_addr: Address,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message_root_proxy_addr: Option<Address>,
    pub transparent_proxy_admin_addr: Address,
    // `Option` to be able to parse configs from pre-gateway protocol version.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stm_deployment_tracker_proxy_addr: Option<Address>,
    // `Option` to be able to parse configs from pre-gateway protocol version.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub native_token_vault_addr: Option<Address>,
    // `Option` to be able to parse configs from pre-gateway protocol version.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chain_asset_handler_proxy_addr: Option<Address>,
}

/// All contracts related to Chain Transition Manager (CTM)
/// This contracts are deployed only once per CTM, ecosystem can have multiple CTMs
#[derive(Debug, Deserialize, Serialize, Clone, Default, PartialEq)]
pub struct ChainTransitionManagerContracts {
    pub governance: Address,
    pub chain_admin: Address,
    pub proxy_admin: Address,
    pub state_transition_proxy_addr: Address,
    pub validator_timelock_addr: Address,
    pub diamond_cut_data: String,
    pub force_deployments_data: Option<String>,
    pub l1_bytecodes_supplier_addr: Address,
    pub l1_wrapped_base_token_store: Option<Address>,
    pub server_notifier_proxy_addr: Address,
    pub default_upgrade_addr: Address,
    pub genesis_upgrade_addr: Address,
    pub verifier_addr: Address,
    pub rollup_l1_da_validator_addr: Address,
    pub no_da_validium_l1_validator_addr: Address,
    pub avail_l1_da_validator_addr: Address,
    pub l1_rollup_da_manager: Address,
    pub blobs_zksync_os_l1_da_validator_addr: Option<Address>,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct BridgesContracts {
    pub erc20: BridgeContractsDefinition,
    pub shared: BridgeContractsDefinition,
    // `Option` to be able to parse configs from pre-gateway protocol version.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub l1_nullifier_addr: Option<Address>,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct BridgeContractsDefinition {
    pub l1_address: Address,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub l2_address: Option<Address>,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct L1CoreContracts {
    pub governance_addr: Address,
    #[serde(default)]
    pub chain_admin_addr: Address,
    // `Option` to be able to parse configs from pre-gateway protocol version.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub access_control_restriction_addr: Option<Address>,
    // `Option` to be able to parse configs from pre-gateway protocol version.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chain_proxy_admin_addr: Option<Address>,
    pub transaction_filterer_addr: Option<Address>,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct EthProofManagerContracts {
    pub proof_manager_addr: Address,
    pub proxy_addr: Address,
    pub proxy_admin_addr: Address,
}
