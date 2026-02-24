use ethers::types::Address;
use serde::{Deserialize, Serialize};

use crate::config::traits::FileConfigTrait;

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DeployChainAdminOutput {
    pub chain_admin_addr: Address,
}

impl FileConfigTrait for DeployChainAdminOutput {}
