use alloy::primitives::{Address, B256};
use serde::{Deserialize, Serialize};

use crate::common::forge::scripts::{Create2Addresses, ForgeScriptParams};
use crate::common::traits::FileConfigTrait;
use crate::types::{DAValidatorType, L2ChainId, VMOption};

pub const REGISTER_CHAIN_SCRIPT_PARAMS: ForgeScriptParams = ForgeScriptParams {
    input: "script-config/register-zk-chain.toml",
    output: "script-out/output-register-zk-chain.toml",
    script_path: "deploy-scripts/ctm/RegisterZKChain.s.sol",
};

pub const DEPLOY_PAYMASTER_SCRIPT_PARAMS: ForgeScriptParams = ForgeScriptParams {
    input: "script-config/config-deploy-paymaster.toml",
    output: "script-out/output-deploy-paymaster.toml",
    script_path: "deploy-scripts/chain/DeployPaymaster.s.sol",
};

pub const SETUP_LEGACY_BRIDGE: ForgeScriptParams = ForgeScriptParams {
    input: "script-config/setup-legacy-bridge.toml",
    output: "script-out/setup-legacy-bridge.toml",
    script_path: "deploy-scripts/dev/SetupLegacyBridge.s.sol",
};

pub const ENABLE_EVM_EMULATOR_PARAMS: ForgeScriptParams = ForgeScriptParams {
    input: "script-config/enable-evm-emulator.toml",
    output: "script-out/output-enable-evm-emulator.toml",
    script_path: "deploy-scripts/chain/EnableEvmEmulator.s.sol",
};

// ── Input types ──────────────────────────────────────────────────────────────

/// Chain parameters
#[derive(Debug, Clone, Serialize)]
pub struct NewChainParams {
    pub chain_id: L2ChainId,
    pub base_token_addr: Address,
    pub base_token_gas_price_multiplier_numerator: u64,
    pub base_token_gas_price_multiplier_denominator: u64,
    pub owner: Address,
    pub commit_operator: Address,
    pub prove_operator: Address,
    pub execute_operator: Address,
    pub token_multiplier_setter: Option<Address>,
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

impl FileConfigTrait for RegisterChainL1Config {}

impl RegisterChainL1Config {
    pub fn new(
        chain_params: &NewChainParams,
        create2_factory_addr: Address,
        create2_factory_salt: Option<B256>,
        initialize_legacy_bridge: bool,
        evm_emulator: bool,
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
                bridgehub_create_new_chain_salt: 0,
                validium_mode: chain_params.da_mode != DAValidatorType::Rollup,
                // TODO fix script to assign roles correctly
                validator_sender_operator_eth: chain_params.prove_operator,
                validator_sender_operator_blobs_eth: chain_params.commit_operator,
                validator_sender_operator_prove: match chain_params.vm_type {
                    VMOption::EraVM => Address::ZERO,
                    VMOption::ZKSyncOsVM => chain_params.prove_operator,
                },
                validator_sender_operator_execute: match chain_params.vm_type {
                    VMOption::EraVM => Address::ZERO,
                    VMOption::ZKSyncOsVM => chain_params.execute_operator,
                },
                allow_evm_emulator: evm_emulator,
            },
            owner_address: chain_params.owner,
            contracts: Create2Addresses {
                create2_factory_addr,
                create2_factory_salt: create2_factory_salt
                    .unwrap_or_else(|| B256::from(rand::random::<[u8; 32]>())),
            },
            initialize_legacy_bridge,
        })
    }
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

// ── Output types ─────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct RegisterChainOutput {
    pub diamond_proxy_addr: Address,
    pub governance_addr: Address,
    pub chain_admin_addr: Address,
    pub l2_legacy_shared_bridge_addr: Option<Address>,
    pub access_control_restriction_addr: Address,
    pub chain_proxy_admin_addr: Address,
}

impl FileConfigTrait for RegisterChainOutput {}
