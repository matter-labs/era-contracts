use ethers::types::Address;
use serde::{Deserialize, Serialize};

use crate::config::traits::FileConfigTrait;

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DeployChainAdminConfig {
    pub owner: Address,
    pub token_multiplier_setter: Address,
}

impl FileConfigTrait for DeployChainAdminConfig {}

impl DeployChainAdminConfig {
    pub fn new(owner: Address, token_multiplier_setter: Option<Address>) -> Self {
        Self {
            owner,
            token_multiplier_setter: token_multiplier_setter.unwrap_or(Address::zero()),
        }
    }
}
