use clap::ValueEnum;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, ValueEnum)]
#[clap(rename_all = "lower")]
pub enum VMOption {
    #[default]
    #[clap(alias = "zksyncos")]
    ZKSyncOsVM,
    #[clap(alias = "era")]
    EraVM,
}

impl VMOption {
    pub fn is_zksync_os(&self) -> bool {
        matches!(self, VMOption::ZKSyncOsVM)
    }
}
