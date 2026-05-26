use alloy::{
    primitives::{Address, FixedBytes, U256},
    sol,
};
use serde::{Deserialize, Serialize};
use std::fs;

use super::{
    get_contents_from_github,
    network_verifier::{Bridgehub, NetworkVerifier},
    repo_relative_path,
};

sol! {
    #[derive(Debug, Default, PartialEq, Eq)]
    enum PubdataPricingMode {
        #[default]
        Rollup,
        Validium
    }

    #[derive(Debug, Default, PartialEq, Eq)]
    struct FeeParams {
        PubdataPricingMode pubdataPricingMode;
        uint32 batchOverheadL1Gas;
        uint32 maxPubdataPerBatch;
        uint32 maxL2GasPerBatch;
        uint32 priorityTxMaxPubdata;
        uint64 minimalL2GasPrice;
    }
}

// This value is the slot in the diamond where the fee params are stored. Taken from
// https://www.notion.so/matterlabs/Upgrade-steps-17aa48363f2380688151e547192e3b79?pvs=4#17aa48363f2380e99862d11605517d54
const FEE_PARAM_STORAGE_SLOT: u8 = 38u8;

#[derive(PartialEq, Eq)]
pub struct FeeParamVerifier {
    pub fee_params: FeeParams,
}

fn word_u32(value: &FixedBytes<32>, offset: usize) -> u32 {
    let mut bytes = [0u8; 4];
    bytes.copy_from_slice(&value.0[offset..offset + 4]);
    u32::from_be_bytes(bytes)
}

fn word_u64(value: &FixedBytes<32>, offset: usize) -> u64 {
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&value.0[offset..offset + 8]);
    u64::from_be_bytes(bytes)
}

impl FeeParamVerifier {
    pub async fn safe_init(
        bridgehub_addr: &Address,
        network_verifier: &NetworkVerifier,
        contracts_commit: Option<&str>,
    ) -> anyhow::Result<Self> {
        let config_based = Self::init_v31_from_source(contracts_commit).await?;
        let era = Self::init_from_on_chain(bridgehub_addr, network_verifier).await?;

        if config_based != era {
            anyhow::bail!(
                "Unexpected difference between SystemConfig.json fee params and live Era diamond fee params.\nSystemConfig.json: {:#?}\nLive Era diamond: {:#?}",
                config_based,
                era
            );
        }

        Ok(Self {
            fee_params: config_based,
        })
    }

    async fn init_v31_from_source(contracts_commit: Option<&str>) -> anyhow::Result<FeeParams> {
        let system_config = SystemConfig::init_v31(contracts_commit).await?;
        Ok(FeeParams {
            pubdataPricingMode: PubdataPricingMode::Rollup,
            batchOverheadL1Gas: system_config.batch_overhead_l1_gas,
            maxPubdataPerBatch: system_config.priority_tx_pubdata_per_batch,
            maxL2GasPerBatch: system_config.priority_tx_max_gas_per_batch,
            priorityTxMaxPubdata: system_config.priority_tx_max_pubdata,
            minimalL2GasPrice: u64::from(system_config.priority_tx_minimal_gas_price),
        })
    }

    pub(crate) async fn init_from_on_chain(
        bridgehub_addr: &Address,
        network_verifier: &NetworkVerifier,
    ) -> anyhow::Result<FeeParams> {
        let bridgehub = Bridgehub::new(*bridgehub_addr, network_verifier.get_l1_provider().clone());

        let diamond_proxy_address = bridgehub
            .getHyperchain(U256::from(network_verifier.era_chain_id))
            .call()
            .await
            .map_err(|e| anyhow::anyhow!("failed to fetch Era diamond from Bridgehub: {e}"))?;

        let value = network_verifier
            .get_storage_at(&diamond_proxy_address, FEE_PARAM_STORAGE_SLOT)
            .await;

        Self::decode_storage_word(value)
    }

    pub(crate) fn decode_storage_word(value: FixedBytes<32>) -> anyhow::Result<FeeParams> {
        let pubdata_pricing_mode = match value.0[31] {
            0 => PubdataPricingMode::Rollup,
            1 => PubdataPricingMode::Validium,
            value => anyhow::bail!("unexpected pubdataPricingMode value {value}"),
        };

        Ok(FeeParams {
            pubdataPricingMode: pubdata_pricing_mode,
            batchOverheadL1Gas: word_u32(&value, 27),
            maxPubdataPerBatch: word_u32(&value, 23),
            maxL2GasPerBatch: word_u32(&value, 19),
            priorityTxMaxPubdata: word_u32(&value, 15),
            minimalL2GasPrice: word_u64(&value, 7),
        })
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
    pub async fn init_v31(contracts_commit: Option<&str>) -> anyhow::Result<Self> {
        if let Some(contracts_commit) = contracts_commit {
            return Self::init_from_github(contracts_commit).await;
        }

        Self::init_from_local()
    }

    fn init_from_local() -> anyhow::Result<Self> {
        let path = repo_relative_path("SystemConfig.json");
        let data = fs::read_to_string(&path)
            .map_err(|e| anyhow::anyhow!("failed to read {}: {e}", path.display()))?;
        serde_json::from_str(&data)
            .map_err(|e| anyhow::anyhow!("failed to parse {}: {e}", path.display()))
    }

    pub async fn init_from_github(commit: &str) -> anyhow::Result<Self> {
        let contents: String = Self::get_contents(commit).await;
        serde_json::from_str(&contents).map_err(|e| {
            anyhow::anyhow!(
                "failed to parse SystemConfig.json from matter-labs/era-contracts@{commit}: {e}"
            )
        })
    }

    async fn get_contents(commit: &str) -> String {
        get_contents_from_github(commit, "matter-labs/era-contracts", "SystemConfig.json").await
    }
}
