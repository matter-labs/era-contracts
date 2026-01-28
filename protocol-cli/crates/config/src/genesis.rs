use std::path::Path;

use ethers::types::H256;
use xshell::Shell;
use protocol_cli_types::{L1ChainId, L2ChainId, L1BatchCommitmentMode};

use crate::raw::RawConfig;

#[derive(Debug)]
pub struct GenesisConfig(pub(crate) RawConfig);

// TODO get rid of the methods. Genesis config now should be used only for getting root data
impl GenesisConfig {
    pub async fn read(shell: &Shell, path: &Path) -> anyhow::Result<Self> {
        RawConfig::read(shell, path).await.map(Self)
    }

    pub fn l1_chain_id(&self) -> anyhow::Result<L1ChainId> {
        self.0.get("l1_chain_id")
    }

    pub fn l2_chain_id(&self) -> anyhow::Result<L2ChainId> {
        self.0.get("l2_chain_id")
    }

    pub fn l1_batch_commitment_mode(&self) -> anyhow::Result<L1BatchCommitmentMode> {
        self.0.get("l1_batch_commit_data_generator_mode")
    }

    pub fn evm_emulator_hash(&self) -> anyhow::Result<Option<H256>> {
        self.0.get_opt("evm_emulator_hash")
    }
}
