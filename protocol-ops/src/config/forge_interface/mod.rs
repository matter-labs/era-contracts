use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};

pub mod deploy_ctm;
pub mod deploy_ecosystem;
pub mod deploy_l2_contracts;
pub mod permanent_values;
pub mod register_chain;
pub mod script_params;

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Create2Addresses {
    pub create2_factory_addr: Address,
    pub create2_factory_salt: H256,
}
