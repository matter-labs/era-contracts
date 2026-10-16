use alloy::primitives::{Address, B256};
use anyhow::Context;
use serde::{Deserialize, Serialize};

use crate::common::forge::scripts::upgrade_executors::UpgradeExecutorsRecord;
use crate::common::traits::FileConfigTrait;

use super::deploy_ecosystem::InitialDeploymentConfig;

// ── Input types ──────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DeployCTMConfig {
    pub owner_address: Address,
    pub testnet_verifier: bool,
    pub contracts: ContractsDeployCTMConfig,
    pub zk_token_asset_id: B256,
    pub multi_proof_verifier: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub zisk_plonk_verifier_addr: Option<Address>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub zisk_range_verifier_addr: Option<Address>,
}

impl FileConfigTrait for DeployCTMConfig {}

#[derive(Debug, Clone, Copy, Default)]
pub struct MultiProofDeployCTMConfig {
    pub enabled: bool,
    pub zisk_plonk_verifier_addr: Option<Address>,
    pub zisk_range_verifier_addr: Option<Address>,
}

impl DeployCTMConfig {
    pub fn new(
        owner_address: Address,
        initial_deployment_config: &InitialDeploymentConfig,
        testnet_verifier: bool,
        zk_token_asset_id: B256,
        multi_proof: MultiProofDeployCTMConfig,
    ) -> Self {
        Self {
            testnet_verifier,
            owner_address,
            zk_token_asset_id,
            multi_proof_verifier: multi_proof.enabled,
            zisk_plonk_verifier_addr: multi_proof.zisk_plonk_verifier_addr,
            zisk_range_verifier_addr: multi_proof.zisk_range_verifier_addr,
            contracts: ContractsDeployCTMConfig {
                create2_factory_addr: initial_deployment_config.create2_factory_addr,
                create2_factory_salt: initial_deployment_config.create2_factory_salt,
                governance_security_council_address: owner_address,
                governance_min_delay: initial_deployment_config.governance_min_delay,
                validator_timelock_execution_delay: initial_deployment_config
                    .validator_timelock_execution_delay,
            },
        }
    }
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ContractsDeployCTMConfig {
    pub create2_factory_salt: B256,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub create2_factory_addr: Option<Address>,
    pub governance_security_council_address: Address,
    pub governance_min_delay: u64,
    pub validator_timelock_execution_delay: u64,
}

// ── Output types ─────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DeployCTMOutput {
    pub contracts_config: DeployCTMContractsConfigOutput,
    pub deployed_addresses: DeployCTMDeployedAddressesOutput,
    pub multicall3_addr: Address,
    /// The CTM executor this run deployed and handed the CTM domain (absent from outputs written
    /// before fresh ecosystems were born into the registry model).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upgrade_executors: Option<UpgradeExecutorsRecord>,
}

impl DeployCTMOutput {
    /// The CTM executor this run deployed.
    pub fn ctm_executor(&self) -> anyhow::Result<Address> {
        self.upgrade_executors
            .as_ref()
            .and_then(|record| record.ctm_executor.as_ref())
            .map(|record| record.address)
            .context(
                "the DeployCTM output has no [upgrade_executors.ctm_executor] record: the script \
                 that ran predates fresh ecosystems owning their CTM through a CTMUpgradeExecutor",
            )
    }
}

impl FileConfigTrait for DeployCTMOutput {}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DeployCTMDeployedAddressesOutput {
    pub governance_addr: Address,
    pub transparent_proxy_admin_addr: Address,
    pub validator_timelock_addr: Address,
    pub chain_admin: Address,
    pub state_transition: L1StateTransitionOutput,
    pub rollup_l1_da_validator_addr: Address,
    pub no_da_validium_l1_validator_addr: Address,
    pub avail_l1_da_validator_addr: Address,
    pub l1_rollup_da_manager: Address,
    pub blobs_zksync_os_l1_da_validator_addr: Option<Address>,
    pub server_notifier_proxy_addr: Address,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DeployCTMContractsConfigOutput {
    pub diamond_cut_data: String,
    pub force_deployments_data: Option<String>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct L1StateTransitionOutput {
    pub state_transition_proxy_addr: Address,
    pub verifier_addr: Address,
    pub airbender_verifier_addr: Option<Address>,
    pub zisk_verifier_addr: Option<Address>,
    pub zisk_testnet_verifier_addr: Option<Address>,
    pub multi_proof_verifier_addr: Option<Address>,
    pub genesis_upgrade_addr: Address,
    pub default_upgrade_addr: Address,
    pub bytecodes_supplier_addr: Address,
    pub interop_fee_manager_proxy_addr: Address,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multiprover_fields_are_serialized_for_the_solidity_script() {
        let plonk = Address::repeat_byte(0x11);
        let range = Address::repeat_byte(0x22);
        let config = DeployCTMConfig::new(
            Address::repeat_byte(0x33),
            &InitialDeploymentConfig::default(),
            true,
            B256::repeat_byte(0x44),
            MultiProofDeployCTMConfig {
                enabled: true,
                zisk_plonk_verifier_addr: Some(plonk),
                zisk_range_verifier_addr: Some(range),
            },
        );

        let serialized = toml::to_string(&config).unwrap();

        assert!(serialized.contains("multi_proof_verifier = true"));
        assert!(serialized.contains(&format!("zisk_plonk_verifier_addr = \"{plonk}\"")));
        assert!(serialized.contains(&format!("zisk_range_verifier_addr = \"{range}\"")));
    }

    /// A DeployCTM output trimmed to its required keys, with `extra` appended.
    fn deploy_ctm_output(extra: &str) -> String {
        let a = "\"0x00000000000000000000000000000000000000a1\"";
        format!(
            "multicall3_addr = {a}\n\
             [contracts_config]\n\
             diamond_cut_data = \"0x\"\n\
             [deployed_addresses]\n\
             governance_addr = {a}\n\
             transparent_proxy_admin_addr = {a}\n\
             validator_timelock_addr = {a}\n\
             chain_admin = {a}\n\
             rollup_l1_da_validator_addr = {a}\n\
             no_da_validium_l1_validator_addr = {a}\n\
             avail_l1_da_validator_addr = {a}\n\
             l1_rollup_da_manager = {a}\n\
             server_notifier_proxy_addr = {a}\n\
             [deployed_addresses.state_transition]\n\
             state_transition_proxy_addr = {a}\n\
             verifier_addr = {a}\n\
             genesis_upgrade_addr = {a}\n\
             default_upgrade_addr = {a}\n\
             bytecodes_supplier_addr = {a}\n\
             interop_fee_manager_proxy_addr = {a}\n\
             {extra}"
        )
    }

    /// The executor record the script writes at the root is carried through to the `--out`
    /// envelope, and `ctm init` reads the CTM executor from it.
    #[test]
    fn the_ctm_executor_record_is_read_from_the_output() {
        let executor = Address::repeat_byte(0xE1);
        let output: DeployCTMOutput = toml::from_str(&deploy_ctm_output(&format!(
            "[upgrade_executors.ctm_executor]\n\
             address = \"{executor}\"\n\
             create2_salt = \"0x{}\"\n\
             initial_owner = \"0x00000000000000000000000000000000000000d1\"\n\
             chain_type_manager = \"0x00000000000000000000000000000000000000c1\"\n\
             ctm_proxy_admin = \"0x00000000000000000000000000000000000000c2\"\n\
             coordinator = \"0x00000000000000000000000000000000000000c3\"\n",
            "5a".repeat(32)
        )))
        .unwrap();
        assert_eq!(output.ctm_executor().unwrap(), executor);
        assert!(toml::to_string(&output)
            .unwrap()
            .contains("[upgrade_executors.ctm_executor]"));
    }

    /// An output from before the CTM executor existed still parses, and `ctm init` refuses it by
    /// name rather than accepting a CTM nobody nominated.
    #[test]
    fn an_output_without_the_executor_record_parses_and_names_what_is_missing() {
        let output: DeployCTMOutput = toml::from_str(&deploy_ctm_output("")).unwrap();
        assert!(output.upgrade_executors.is_none());
        let err = output.ctm_executor().unwrap_err().to_string();
        assert!(err.contains("upgrade_executors.ctm_executor"), "{err}");
    }

    #[test]
    fn optional_multiprover_addresses_are_omitted() {
        let config = DeployCTMConfig::new(
            Address::repeat_byte(0x33),
            &InitialDeploymentConfig::default(),
            true,
            B256::repeat_byte(0x44),
            MultiProofDeployCTMConfig::default(),
        );

        let serialized = toml::to_string(&config).unwrap();

        assert!(serialized.contains("multi_proof_verifier = false"));
        assert!(!serialized.contains("zisk_plonk_verifier_addr"));
        assert!(!serialized.contains("zisk_range_verifier_addr"));
    }

    #[test]
    fn interop_fee_manager_survives_the_output_round_trip() {
        let manager = Address::repeat_byte(0x55);
        let output: L1StateTransitionOutput = toml::from_str(&format!(
            r#"
            state_transition_proxy_addr = "{zero}"
            verifier_addr = "{zero}"
            genesis_upgrade_addr = "{zero}"
            default_upgrade_addr = "{zero}"
            bytecodes_supplier_addr = "{zero}"
            interop_fee_manager_proxy_addr = "{manager}"
            "#,
            zero = Address::ZERO
        ))
        .unwrap();

        let serialized = toml::to_string(&output).unwrap();

        assert!(serialized.contains(&format!("interop_fee_manager_proxy_addr = \"{manager}\"")));
    }
}
