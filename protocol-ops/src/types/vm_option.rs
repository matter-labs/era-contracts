use clap::ValueEnum;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, ValueEnum)]
#[clap(rename_all = "lower")]
pub enum VMOption {
    #[default]
    #[clap(alias = "era-vm")]
    EraVM,
    #[clap(alias = "zk-sync-os-vm", alias = "zksync-os-vm", alias = "zksyncos")]
    ZKSyncOsVM,
}

impl VMOption {
    pub fn is_zksync_os(&self) -> bool {
        matches!(self, VMOption::ZKSyncOsVM)
    }
}
