//! The `AllContractsHashes.json` model — the committed record of what each contract's
//! compiled bytecode hashes to.
//!
//! Version-independent on purpose: it is how any verifier answers "is the code at this
//! address the code the reviewed commit produces?". The v31 verifier adds GitHub-fetching
//! and filtering constructors to `ContractHashes` in its own module.

use std::fs;

use anyhow::Context;
use serde::{Deserialize, Serialize};

use crate::upgrade_verification::paths::repo_relative_path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContractHash {
    #[serde(rename = "contractName")]
    pub contract_name: String,
    #[serde(rename = "evmBytecodeHash")]
    pub evm_bytecode_hash: Option<String>,
    #[serde(rename = "evmDeployedBytecodeHash")]
    pub evm_deployed_bytecode_hash: Option<String>,
    #[serde(rename = "evmDeployedBytecodeBlakeHash")]
    #[serde(default)]
    pub evm_deployed_bytecode_blake_hash: Option<String>,
    #[serde(rename = "evmDeployedBytecodeLength")]
    #[serde(default)]
    pub evm_deployed_bytecode_length: Option<u32>,
    #[serde(rename = "zkBytecodeHash")]
    pub zk_bytecode_hash: Option<String>,
}

#[derive(Debug)]
pub struct ContractHashes {
    pub hashes: Vec<ContractHash>,
}

impl ContractHashes {
    pub fn init_from_local() -> anyhow::Result<Self> {
        const LOCAL_CONTRACT_HASHES_PATH: &str = "AllContractsHashes.json";

        let path = repo_relative_path(LOCAL_CONTRACT_HASHES_PATH);
        let contents = fs::read_to_string(&path).with_context(|| {
            format!(
                "failed to read {}; run `yarn calculate-hashes:fix` or \
                 `npx ts-node scripts/calculate-hashes.ts` from the repository root, or pass \
                 `--contracts-commit` to fetch AllContractsHashes.json from GitHub",
                path.display()
            )
        })?;

        Ok(Self {
            hashes: serde_json::from_str(&contents)
                .context("failed to parse local AllContractsHashes.json")?,
        })
    }
}
