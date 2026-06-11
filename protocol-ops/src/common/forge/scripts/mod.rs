use std::path::{Path, PathBuf};

use alloy::primitives::{Address, B256};
use serde::{Deserialize, Serialize};

pub mod admin;
pub mod deploy_ctm;
pub mod deploy_ecosystem;
pub mod deploy_l2_contracts;
pub mod register_chain;

#[derive(PartialEq, Debug, Clone)]
pub struct ForgeScriptParams {
    input: &'static str,
    output: &'static str,
    script_path: &'static str,
}

impl ForgeScriptParams {
    pub fn input(&self, path_to_l1_foundry: &Path) -> PathBuf {
        path_to_l1_foundry.join(self.input)
    }

    pub fn output(&self, path_to_l1_foundry: &Path) -> PathBuf {
        path_to_l1_foundry.join(self.output)
    }

    pub fn script(&self) -> PathBuf {
        PathBuf::from(self.script_path)
    }
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Create2Addresses {
    pub create2_factory_addr: Address,
    pub create2_factory_salt: B256,
}
