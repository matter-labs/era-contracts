use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};

pub mod accept_ownership;
pub mod deploy_ctm;
pub mod deploy_ecosystem;
pub mod deploy_l2_contracts;
pub mod register_chain;
pub mod script_params;

// pub mod deploy_gateway_tx_filterer;
// pub mod gateway_preparation;
// pub mod gateway_vote_preparation;
// pub mod paymaster;
// pub mod setup_legacy_bridge;
// pub mod upgrade_ecosystem;

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Create2Addresses {
    pub create2_factory_addr: Address,
    pub create2_factory_salt: H256,
}
