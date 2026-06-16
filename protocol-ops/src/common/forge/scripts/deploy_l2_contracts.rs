use alloy::primitives::Address;
use serde::{Deserialize, Serialize};

use crate::common::traits::FileConfigTrait;

pub use super::DEPLOY_L2_CONTRACTS_INVOCATION as DEPLOY_L2_CONTRACTS_SCRIPT_PARAMS;

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
