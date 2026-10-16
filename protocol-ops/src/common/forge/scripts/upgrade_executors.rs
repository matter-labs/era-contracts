//! The `[upgrade_executors]` record every run that deploys an upgrade executor writes
//! (`deploy-scripts/utils/UpgradeExecutorsRecord.sol`): each executor's address, the CREATE2 salt
//! it was deployed under and its ORIGINAL constructor arguments. The verifier re-derives an
//! executor's construction from it after its owner or coordinator has moved
//! (`ecosystem verify-package --executor-record`).
//!
//! ```toml
//! [upgrade_executors.core_executor]   # DeployL1CoreContracts, CoreUpgrade_v35
//! [upgrade_executors.coordinator]     # DeployL1CoreContracts, CoreUpgrade_v35
//! [upgrade_executors.ctm_executor]    # DeployCTM, CTMUpgrade_v35
//! ```

use alloy::primitives::{Address, B256};
use serde::{Deserialize, Serialize};

/// `CoreUpgradeExecutor(_initialOwner, _proxyAdmin)`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CoreExecutorRecord {
    pub address: Address,
    pub create2_salt: B256,
    pub initial_owner: Address,
    pub proxy_admin: Address,
}

/// `EcosystemUpgradeExecutor(_initialOwner, _coreExecutor)`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CoordinatorRecord {
    pub address: Address,
    pub create2_salt: B256,
    pub initial_owner: Address,
    pub core_executor: Address,
}

/// `CTMUpgradeExecutor(_initialOwner, _ctm, _ctmProxyAdmin, _coordinator)`. `coordinator` is the
/// CONSTRUCTOR value; the live one may have moved since (`setCoordinator`).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CtmExecutorRecord {
    pub address: Address,
    pub create2_salt: B256,
    pub initial_owner: Address,
    pub chain_type_manager: Address,
    pub ctm_proxy_admin: Address,
    pub coordinator: Address,
}

/// One `[upgrade_executors]` table: whichever executors the run deployed.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct UpgradeExecutorsRecord {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub core_executor: Option<CoreExecutorRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coordinator: Option<CoordinatorRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ctm_executor: Option<CtmExecutorRecord>,
}

impl UpgradeExecutorsRecord {
    pub fn is_empty(&self) -> bool {
        self.core_executor.is_none() && self.coordinator.is_none() && self.ctm_executor.is_none()
    }
}
