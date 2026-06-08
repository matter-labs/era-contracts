use alloy::primitives::Address;
use serde::{Deserialize, Serialize};

use crate::common::forge::scripts::ForgeScriptParams;
use crate::common::traits::FileConfigTrait;

pub const DEPLOY_L2_CONTRACTS_SCRIPT_PARAMS: ForgeScriptParams = ForgeScriptParams {
    input: "script-config/config-deploy-l2-contracts.toml",
    output: "script-out/output-deploy-l2-contracts.toml",
    script_path: "deploy-scripts/chain/DeployL2Contracts.sol",
};

// ── Output types ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DefaultL2UpgradeOutput {
    pub l2_default_upgrader: Address,
}

impl FileConfigTrait for DefaultL2UpgradeOutput {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConsensusRegistryOutput {
    pub consensus_registry_implementation: Address,
    pub consensus_registry_proxy: Address,
}

impl FileConfigTrait for ConsensusRegistryOutput {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Multicall3Output {
    pub multicall3: Address,
}

impl FileConfigTrait for Multicall3Output {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimestampAsserterOutput {
    pub timestamp_asserter: Address,
}

impl FileConfigTrait for TimestampAsserterOutput {}
