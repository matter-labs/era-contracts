use alloy::primitives::{Address, FixedBytes, U256};
use anyhow::Context;
use call_list::CallList;
use deployed_addresses::DeployedAddresses;
use governance_stage_calls::{GovernanceStage0Calls, GovernanceStage1Calls, GovernanceStage2Calls};
use initialize_data_new_chain::{FeeParams, PubdataPricingMode};
use protocol_version::ProtocolVersion;
use serde::Deserialize;

use crate::upgrade_verification::verifiers::{VerificationResult, Verifiers};

use super::{
    get_expected_new_protocol_version, get_expected_old_protocol_version,
    utils::address_verifier::AddressVerifier, MAX_PRIORITY_TX_GAS_LIMIT,
};

pub mod call_list;
pub mod deployed_addresses;
pub mod fixed_force_deployment;
pub mod force_deployment;
pub mod governance_stage_calls;
pub mod initialize_data_new_chain;
pub mod protocol_version;
pub mod set_new_version_upgrade;

#[derive(Debug, Deserialize)]
pub struct UpgradeOutput {
    pub(crate) chain_upgrade_diamond_cut: String,
    pub(crate) create2_factory_addr: Address,
    pub(crate) create2_factory_salt: FixedBytes<32>,
    pub(crate) deployer_addr: Address,
    pub(crate) era_chain_id: u64,

    pub(crate) governance_calls: GovernanceCalls,

    pub(crate) l1_chain_id: u64,

    pub(crate) gateway_chain_id: u64,

    pub(crate) protocol_upgrade_handler_proxy_address: Address,

    #[serde(rename = "contracts_newConfig")]
    pub(crate) contracts_config: ContractsConfig,
    pub(crate) deployed_addresses: DeployedAddresses,

    pub(crate) transactions: Vec<String>,

    pub(crate) gateway: Gateway,

    #[allow(dead_code)]
    pub(crate) max_expected_l1_gas_price: u64,
    pub(crate) priority_txs_l2_gas_limit: u64,
}

#[derive(Debug, Deserialize)]
pub struct GovernanceCalls {
    pub(crate) governance_stage0_calls: String,
    pub(crate) governance_stage1_calls: String,
    pub(crate) governance_stage2_calls: String,
}

#[derive(Debug, Deserialize, Clone)]
pub(crate) struct ContractsConfig {
    diamond_cut_data: String,
    diamond_init_batch_overhead_l1_gas: u32,
    diamond_init_max_l2_gas_per_batch: u32,
    diamond_init_max_pubdata_per_batch: u32,
    diamond_init_minimal_l2_gas_price: u64,
    diamond_init_priority_tx_max_pubdata: u32,
    // todo: maybe convert to enum rightaway
    diamond_init_pubdata_pricing_mode: u32,
    force_deployments_data: String,
    l1_legacy_shared_bridge: Address,
    new_protocol_version: u64,
    old_protocol_version: u64,
    old_validator_timelock: Address,
    priority_tx_max_gas_limit: u32,
    recursion_circuits_set_vks_hash: FixedBytes<32>,
    recursion_leaf_level_vk_hash: FixedBytes<32>,
    recursion_node_level_vk_hash: FixedBytes<32>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct Gateway {
    pub diamond_cut_data: String,
    pub upgrade_cut_data: String,
    pub gateway_state_transition: GatewayStateTransition,
}

#[derive(Debug, Deserialize)]
pub(crate) struct GatewayStateTransition {
    pub admin_facet_addr: Address,
    pub chain_type_manager_implementation_addr: Address,
    pub chain_type_manager_proxy: Address,
    pub diamond_init_addr: Address,
    pub executor_facet_addr: Address,
    pub genesis_upgrade_addr: Address,
    pub default_upgrade_addr: Address,
    pub getters_facet_addr: Address,
    pub mailbox_facet_addr: Address,
    pub verifier_addr: Address,
    pub verifier_fflonk_addr: Address,
    pub verifier_plonk_addr: Address,
    pub rollup_da_manager: Address,
    pub rollup_l2_da_validator: Address,
}

impl ContractsConfig {
    pub async fn verify(
        &self,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
        expected_diamond_cut_data: String,
        expected_force_deployments: String,
    ) {
        if expected_diamond_cut_data != self.diamond_cut_data[2..] {
            result.report_error(&format!(
                "Initial diamondcutdata mismatch.\nExpected: {}\nReceived: {}",
                expected_diamond_cut_data,
                &self.diamond_cut_data[2..]
            ));
        }

        let provided_fee_params = FeeParams {
            pubdataPricingMode: if self.diamond_init_pubdata_pricing_mode == 0 {
                PubdataPricingMode::Rollup
            } else {
                PubdataPricingMode::Validium
            },
            batchOverheadL1Gas: self.diamond_init_batch_overhead_l1_gas,
            maxPubdataPerBatch: self.diamond_init_max_pubdata_per_batch,
            maxL2GasPerBatch: self.diamond_init_max_l2_gas_per_batch,
            priorityTxMaxPubdata: self.diamond_init_priority_tx_max_pubdata,
            minimalL2GasPrice: self.diamond_init_minimal_l2_gas_price,
        };
        if provided_fee_params != verifiers.fee_param_verifier.fee_params {
            result.report_error(&format!(
                "Diamond init fee params mismatch.\nExpected: {:#?}\nReceived: {:#?}",
                verifiers.fee_param_verifier.fee_params, provided_fee_params
            ));
        }

        if expected_force_deployments != self.force_deployments_data[2..] {
            result.report_error(&format!(
                "Fixed force deployment data mismatch.\nExpected: {}\nReceived: {}",
                expected_force_deployments,
                &self.force_deployments_data[2..]
            ));
        }

        result.expect_address(
            verifiers,
            &self.l1_legacy_shared_bridge,
            "l1_asset_router_proxy",
        );

        let provided_new_protocol_version =
            ProtocolVersion::from(U256::from(self.new_protocol_version));
        if provided_new_protocol_version != get_expected_new_protocol_version() {
            result.report_error(&format!(
                "Invalid protocol version provided.\nExpected: {}\nReceived: {}",
                get_expected_new_protocol_version(),
                provided_new_protocol_version
            ));
        }

        let provided_old_protocol_version =
            ProtocolVersion::from(U256::from(self.old_protocol_version));
        if provided_old_protocol_version != get_expected_old_protocol_version() {
            result.report_error(&format!(
                "Invalid protocol version provided.\nExpected: {}\nReceived: {}",
                get_expected_old_protocol_version(),
                provided_old_protocol_version
            ));
        }

        result.expect_address(
            verifiers,
            &self.old_validator_timelock,
            "old_validator_timelock",
        );

        if self.priority_tx_max_gas_limit != MAX_PRIORITY_TX_GAS_LIMIT {
            result.report_error(&format!(
                "Invalid priority tx max gas limit.\nExpected: {}\nReceived: {}",
                MAX_PRIORITY_TX_GAS_LIMIT, self.priority_tx_max_gas_limit
            ));
        }

        if self.recursion_circuits_set_vks_hash != [0u8; 32]
            || self.recursion_leaf_level_vk_hash != [0u8; 32]
            || self.recursion_node_level_vk_hash != [0u8; 32]
        {
            result.report_error("Verifier params must be empty.");
        }
    }
}

impl UpgradeOutput {
    pub fn add_to_verifier(&self, address_verifier: &mut AddressVerifier) {
        self.deployed_addresses.add_to_verifier(address_verifier);
    }

    pub async fn verify(
        &self,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        result.print_info("== Config verification ==");

        let provider_chain_id = verifiers.network_verifier.get_era_chain_id();
        if provider_chain_id == self.era_chain_id {
            result.report_ok("Chain id");
        } else {
            result.report_error(&format!(
                "chain id mismatch: {} vs {} ",
                self.era_chain_id, provider_chain_id
            ));
        }

        if self.l1_chain_id == verifiers.network_verifier.get_l1_chain_id() {
            result.report_ok("L1 chain id");
        } else {
            result.report_error(&format!(
                "L1 chain id mismatch: {} vs {} ",
                self.l1_chain_id,
                verifiers.network_verifier.get_l1_chain_id()
            ));
        }

        // Check that addresses actually contain correct bytecodes.
        self.deployed_addresses
            .verify(self, verifiers, result)
            .await
            .context("checking deployed addresses")?;
        let (l1_facets_to_remove, l1_facets_to_add) = self
            .deployed_addresses
            .get_expected_facet_cuts(verifiers, result, false)
            .await
            .context("checking facets")?;

        result
            .expect_deployed_bytecode(verifiers, &self.create2_factory_addr, "Create2Factory")
            .await;

        let stage0 = GovernanceStage0Calls {
            calls: CallList::parse(&self.governance_calls.governance_stage0_calls),
        };

        stage0.verify(verifiers, result).context("stage0")?;

        let stage1 = GovernanceStage1Calls {
            calls: CallList::parse(&self.governance_calls.governance_stage1_calls),
        };

        let l1_expected_upgrade_facets =
            l1_facets_to_remove.merge(l1_facets_to_add.clone()).clone();
        let (l1_expected_chain_creation_data, l1_expected_force_deployments) = stage1
            .verify(
                verifiers,
                result,
                l1_facets_to_add.clone(),
                l1_expected_upgrade_facets,
                &self.chain_upgrade_diamond_cut,
                self.deployed_addresses.l1_bytecodes_supplier_addr,
            )
            .await
            .context("stage1")?;

        let stage2 = GovernanceStage2Calls {
            calls: CallList::parse(&self.governance_calls.governance_stage2_calls),
        };

        stage2.verify(verifiers, result).context("stage2")?;

        self.contracts_config
            .verify(
                verifiers,
                result,
                l1_expected_chain_creation_data,
                l1_expected_force_deployments,
            )
            .await;

        Ok(())
    }
}
