use alloy::{
    primitives::{Address, U256},
    sol_types::SolValue,
};
use serde::{Deserialize, Serialize};

use super::super::elements::initialize_data_new_chain::{FeeParams, PubdataPricingMode};

use super::{
    get_contents_from_github,
    network_verifier::{Bridgehub, NetworkVerifier},
};

// This value is the slot in the diamond where the fee params are stored. Taken from
// https://www.notion.so/matterlabs/Upgrade-steps-17aa48363f2380688151e547192e3b79?pvs=4#17aa48363f2380e99862d11605517d54
const FEE_PARAM_STORAGE_SLOT: u8 = 38u8;

#[derive(PartialEq, Eq)]
pub struct FeeParamVerifier {
    pub fee_params: FeeParams,
}

fn expand_to_word(slice: &[u8]) -> Vec<u8> {
    assert!(slice.len() <= 32);

    let mut result = vec![0u8; 32];
    result[32 - slice.len()..32].copy_from_slice(slice);

    result
}

impl FeeParamVerifier {
    pub fn empty() -> Self {
        Self {
            fee_params: FeeParams {
                pubdataPricingMode: PubdataPricingMode::Rollup,
                batchOverheadL1Gas: 0,
                maxPubdataPerBatch: 0,
                maxL2GasPerBatch: 0,
                priorityTxMaxPubdata: 0,
                minimalL2GasPrice: 0,
            },
        }
    }

    pub async fn safe_init(
        bridgehub_addr: &Address,
        network_verifier: &NetworkVerifier,
        contracts_commit: &str,
    ) -> Self {
        let github_based = Self::init_from_github(contracts_commit).await;
        let era = Self::init_from_on_chain(bridgehub_addr, network_verifier).await;

        if github_based != era {
            panic!("Unexpected difference between github-based config and L1-based one");
        }

        Self {
            fee_params: github_based,
        }
    }

    async fn init_from_github(commit: &str) -> FeeParams {
        let system_config = SystemConfig::init_from_github(commit).await;
        FeeParams {
            pubdataPricingMode: PubdataPricingMode::Rollup,
            batchOverheadL1Gas: system_config.batch_overhead_l1_gas,
            maxPubdataPerBatch: system_config.priority_tx_pubdata_per_batch,
            maxL2GasPerBatch: system_config.priority_tx_max_gas_per_batch,
            priorityTxMaxPubdata: system_config.priority_tx_max_pubdata,
            minimalL2GasPrice: u64::from(system_config.priority_tx_minimal_gas_price),
        }
    }

    async fn init_from_on_chain(
        bridgehub_addr: &Address,
        network_verifier: &NetworkVerifier,
    ) -> FeeParams {
        let bridgehub = Bridgehub::new(*bridgehub_addr, network_verifier.get_l1_provider().clone());

        let diamond_proxy_address = &bridgehub
            .getHyperchain(U256::from(network_verifier.l2_chain_id))
            .call()
            .await
            .unwrap();

        let value = network_verifier
            .get_storage_at(diamond_proxy_address, FEE_PARAM_STORAGE_SLOT)
            .await;

        FeeParams {
            pubdataPricingMode: PubdataPricingMode::abi_decode(&expand_to_word(&value.0[31..32]))
                .unwrap(),
            batchOverheadL1Gas: u32::abi_decode(&expand_to_word(&value.0[27..31])).unwrap(),
            maxPubdataPerBatch: u32::abi_decode(&expand_to_word(&value.0[23..27])).unwrap(),
            maxL2GasPerBatch: u32::abi_decode(&expand_to_word(&value.0[19..23])).unwrap(),
            priorityTxMaxPubdata: u32::abi_decode(&expand_to_word(&value.0[15..19])).unwrap(),
            minimalL2GasPrice: u64::abi_decode(&expand_to_word(&value.0[7..15])).unwrap(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SystemConfig {
    #[serde(rename = "GUARANTEED_PUBDATA_BYTES")]
    pub guaranteed_pubdata_bytes: u32,
    #[serde(rename = "MAX_TRANSACTIONS_IN_BATCH")]
    pub max_transactions_in_batch: u32,
    #[serde(rename = "REQUIRED_L2_GAS_PRICE_PER_PUBDATA")]
    pub required_l2_gas_price_per_pubdata: u32,
    #[serde(rename = "L1_GAS_PER_PUBDATA_BYTE")]
    pub l1_gas_per_pubdata_byte: u32,
    #[serde(rename = "PRIORITY_TX_MAX_PUBDATA")]
    pub priority_tx_max_pubdata: u32,
    #[serde(rename = "BATCH_OVERHEAD_L1_GAS")]
    pub batch_overhead_l1_gas: u32,
    #[serde(rename = "L1_TX_INTRINSIC_L2_GAS")]
    pub l1_tx_intrinsic_l2_gas: u32,
    #[serde(rename = "L1_TX_INTRINSIC_PUBDATA")]
    pub l1_tx_intrinsic_pubdata: u32,
    #[serde(rename = "L1_TX_MIN_L2_GAS_BASE")]
    pub l1_tx_min_l2_gas_base: u32,
    #[serde(rename = "L1_TX_DELTA_544_ENCODING_BYTES")]
    pub l1_tx_delta_544_encoding_bytes: u32,
    #[serde(rename = "L1_TX_DELTA_FACTORY_DEPS_L2_GAS")]
    pub l1_tx_delta_factory_deps_l2_gas: u32,
    #[serde(rename = "L1_TX_DELTA_FACTORY_DEPS_PUBDATA")]
    pub l1_tx_delta_factory_deps_pubdata: u32,
    #[serde(rename = "L2_TX_INTRINSIC_GAS")]
    pub l2_tx_intrinsic_gas: u32,
    #[serde(rename = "L2_TX_INTRINSIC_PUBDATA")]
    pub l2_tx_intrinsic_pubdata: u32,
    #[serde(rename = "MAX_NEW_FACTORY_DEPS")]
    pub max_new_factory_deps: u32,
    #[serde(rename = "MAX_GAS_PER_TRANSACTION")]
    pub max_gas_per_transaction: u32,
    #[serde(rename = "KECCAK_ROUND_COST_GAS")]
    pub keccak_round_cost_gas: u32,
    #[serde(rename = "SHA256_ROUND_COST_GAS")]
    pub sha256_round_cost_gas: u32,
    #[serde(rename = "ECRECOVER_COST_GAS")]
    pub ecrecover_cost_gas: u32,
    #[serde(rename = "PRIORITY_TX_MINIMAL_GAS_PRICE")]
    pub priority_tx_minimal_gas_price: u32,
    #[serde(rename = "PRIORITY_TX_MAX_GAS_PER_BATCH")]
    pub priority_tx_max_gas_per_batch: u32,
    #[serde(rename = "PRIORITY_TX_PUBDATA_PER_BATCH")]
    pub priority_tx_pubdata_per_batch: u32,
    #[serde(rename = "PRIORITY_TX_BATCH_OVERHEAD_L1_GAS")]
    pub priority_tx_batch_overhead_l1_gas: u32,
}

impl SystemConfig {
    pub async fn init_from_github(commit: &str) -> Self {
        let contents: String = Self::get_contents(commit).await;
        serde_json::from_str(&contents).expect("Failed to parse JSON")
    }

    async fn get_contents(commit: &str) -> String {
        get_contents_from_github(commit, "matter-labs/era-contracts", "SystemConfig.json").await
    }
}
