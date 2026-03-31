use crate::types::{DAValidatorType, L2ChainId, VMOption};
use ethers::types::Address;
use ethers::types::H256;
use rand::Rng;
use serde::{Deserialize, Serialize};

use crate::common::traits::FileConfigTrait;
use crate::config::forge_interface::Create2Addresses;

/// Chain parameters
#[derive(Debug, Clone, Serialize)]
pub struct NewChainParams {
    pub chain_id: L2ChainId,
    pub base_token_addr: Address,
    pub base_token_gas_price_multiplier_numerator: u64,
    pub base_token_gas_price_multiplier_denominator: u64,
    pub owner: Address,
    /// Eth-path ZKsync Era validator (`validator_sender_operator_eth` — not OS commit/prove/execute).
    pub era_validator_operator: Address,
    /// ZKsync OS L1 commit operator (`validator_sender_operator_blobs_eth`, committer role).
    pub commit_operator: Address,
    /// ZKsync OS L1 prove operator (`validator_sender_operator_prove`).
    pub prove_operator: Address,
    /// ZKsync OS L1 execute operator (`validator_sender_operator_execute`).
    pub execute_operator: Address,
    pub _token_multiplier_setter: Option<Address>,
    pub da_mode: DAValidatorType,
    pub vm_type: VMOption,
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
    pub validator_sender_operator_prove: Address,
    pub validator_sender_operator_execute: Address,
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
        create2_factory_salt: Option<H256>,
        initialize_legacy_bridge: bool,
    ) -> anyhow::Result<Self> {
        Ok(Self {
            chain: ChainL1Config {
                chain_chain_id: chain_params.chain_id,
                base_token_gas_price_multiplier_nominator: chain_params
                    .base_token_gas_price_multiplier_numerator,
                base_token_gas_price_multiplier_denominator: chain_params
                    .base_token_gas_price_multiplier_denominator,
                base_token_addr: chain_params.base_token_addr,
                // TODO specify
                governance_security_council_address: Default::default(),
                governance_min_delay: 0,
                // TODO verify
                bridgehub_create_new_chain_salt: rand::thread_rng().gen_range(0..=i64::MAX) as u64,
                validium_mode: chain_params.da_mode == DAValidatorType::NoDA
                    || chain_params.da_mode == DAValidatorType::Avail,
                validator_sender_operator_eth: chain_params.era_validator_operator,
                validator_sender_operator_blobs_eth: chain_params.commit_operator,
                validator_sender_operator_prove: chain_params.prove_operator,
                validator_sender_operator_execute: chain_params.execute_operator,
                allow_evm_emulator: true,
            },
            owner_address: chain_params.owner,
            contracts: Create2Addresses {
                create2_factory_addr,
                create2_factory_salt: create2_factory_salt.unwrap_or_else(H256::random),
            },
            initialize_legacy_bridge,
        })
    }
}
