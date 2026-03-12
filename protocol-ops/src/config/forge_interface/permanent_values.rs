use std::path::{Path, PathBuf};

use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};

use crate::common::traits::FileConfigTrait;

/// Relative path from the foundry project root to permanent-values.toml.
const PERMANENT_VALUES_PATH: &str = "script-config/permanent-values.toml";

/// Config that maps to permanent-values.toml read by Forge deploy scripts.
#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct PermanentValuesConfig {
    pub permanent_contracts: PermanentContracts,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct PermanentContracts {
    pub create2_factory_addr: Address,
    pub create2_factory_salt: H256,
}

impl FileConfigTrait for PermanentValuesConfig {}

impl PermanentValuesConfig {
    pub fn new(create2_factory_addr: Option<Address>, create2_factory_salt: H256) -> Self {
        Self {
            permanent_contracts: PermanentContracts {
                create2_factory_addr: create2_factory_addr.unwrap_or_default(),
                create2_factory_salt,
            },
        }
    }

    /// Full path to permanent-values.toml given the foundry project root.
    pub fn path(foundry_scripts_path: &Path) -> PathBuf {
        foundry_scripts_path.join(PERMANENT_VALUES_PATH)
    }
}
