use std::{path::Path, str::FromStr};

use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};
use xshell::Shell;
use protocol_cli_types::VMOption;

use crate::{
    consts::CONTRACTS_FILE,
    forge_interface::{
        deploy_ecosystem::output::{DeployCTMOutput, DeployL1CoreContractsOutput},
    },
    traits::{FileConfigTrait, FileConfigWithDefaultName, ReadConfig},
};

#[derive(Debug, Deserialize, Serialize, Clone, Default)]
pub struct ProtocolConfig {
    pub foundry_scripts_path: PathBuf,
}

