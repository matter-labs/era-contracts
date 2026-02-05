use ethers::types::Address;
use rand::Rng;
use serde::{Deserialize, Serialize};
use ethers::types::H256;
use protocol_cli_types::{L2ChainId, DAValidatorType, VMOption};

use crate::{forge_interface::Create2Addresses, traits::FileConfigTrait, CoreContractsConfig};

/// Chain parameters
#[derive(Debug, Clone)]
pub struct NewChainParams {
    pub chain_id: L2ChainId,
    pub base_token_addr: Address,
    pub base_token_gas_price_multiplier_numerator: u64,
    pub base_token_gas_price_multiplier_denominator: u64,
    pub owner: Address,
    pub commit_operator: Address,
    pub prove_operator: Address,
    pub execute_operator: Option<Address>,
    pub token_multiplier_setter: Option<Address>,
    pub da_mode: DAValidatorType,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct RegisterChainL1Config {
    chain: ChainL1Config,
    owner_address: Address,
    contracts: Create2Addresses,
    initialize_legacy_bridge: bool,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ChainL1Config {
    pub chain_chain_id: L2ChainId,
    pub base_token_addr: Address,
    pub bridgehub_create_new_chain_salt: u64,
    pub validium_mode: bool,
    pub validator_sender_operator_eth: Address,
    pub validator_sender_operator_blobs_eth: Address,
    pub base_token_gas_price_multiplier_nominator: u64,
    pub base_token_gas_price_multiplier_denominator: u64,
    pub governance_security_council_address: Address,
    pub governance_min_delay: u64,
    pub allow_evm_emulator: bool,
}

impl FileConfigTrait for RegisterChainL1Config {}

impl RegisterChainL1Config {
    pub fn new(
        chain_params: &NewChainParams,
        create2_factory_addr: Address,
        initialize_legacy_bridge: bool,
    ) -> anyhow::Result<Self> {
        Ok(Self {
            chain: ChainL1Config {
                chain_chain_id: chain_params.chain_id,
                base_token_gas_price_multiplier_nominator: chain_params.base_token_gas_price_multiplier_numerator,
                base_token_gas_price_multiplier_denominator: chain_params.base_token_gas_price_multiplier_denominator,
                base_token_addr: chain_params.base_token_addr,
                // TODO specify
                governance_security_council_address: Default::default(),
                governance_min_delay: 0,
                // TODO verify
                bridgehub_create_new_chain_salt: rand::thread_rng().gen_range(0..=i64::MAX) as u64,
                validium_mode: chain_params.da_mode == DAValidatorType::NoDA || chain_params.da_mode == DAValidatorType::Avail,
                validator_sender_operator_eth: chain_params.commit_operator,
                validator_sender_operator_blobs_eth: chain_params.prove_operator,                
                allow_evm_emulator: true,
            },
            owner_address: chain_params.owner,
            contracts: Create2Addresses {
                create2_factory_addr,
                create2_factory_salt: H256::random(),
            },
            initialize_legacy_bridge,
        })
    }
}
