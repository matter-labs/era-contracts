// TODO: drop once R2 (fee-params) scaffolding lands or is deleted, alongside
// the D13 cleanup (legacy `GovernanceStage{0,1,2}Calls::verify` etc.).
#![allow(dead_code)]

use alloy::{
    hex::{self, FromHex},
    primitives::{Address, Bytes, FixedBytes},
    sol,
    sol_types::SolCall,
};
use colored::Colorize;
use serde::Deserialize;
use std::fmt::{self, Display};
use std::fs;
use std::panic::Location;

use crate::upgrade_verification::{
    artifacts::{CtmFlavor, EcosystemUpgradeArtifact},
    constants::L2_BRIDGEHUB_ADDR,
    versions::v31::utils::{
        address_verifier::AddressVerifier, bytecode_verifier::BytecodeVerifier,
        fee_param_verifier::FeeParamVerifier, get_contents_from_github,
        network_verifier::NetworkVerifier, repo_relative_path,
    },
};

sol! {
    function transparentProxyConstructor(address impl, address initialAdmin, bytes memory initCalldata);
}

/// Holds various verifiers and configuration parameters.
pub(crate) struct Verifiers {
    pub testnet_contracts: bool,
    pub bridgehub_address: Address,
    pub address_verifier: AddressVerifier,
    pub bytecode_verifier: BytecodeVerifier,
    pub network_verifier: NetworkVerifier,
    pub era_genesis_config: GenesisConfig,
    pub zksync_os_genesis_config: GenesisConfig,
    pub fee_param_verifier: FeeParamVerifier,
    pub gateway_bridgehub_address: Address,
    pub representative_era_chain_id: Option<u64>,
    pub zk_token_asset_id: FixedBytes<32>,
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum GenesisConfigKind {
    Era,
    ZksyncOs,
}

impl GenesisConfigKind {
    fn local_path(self) -> &'static str {
        match self {
            Self::Era => "configs/genesis/era/latest.json",
            Self::ZksyncOs => "configs/genesis/zksync-os/latest.json",
        }
    }
}

impl Verifiers {
    /// Creates a v31 verifier context from the single ecosystem TOML.
    ///
    /// This keeps the copied PUVT shape intact: as more v31 parity checks are
    /// restored, the placeholder verifier fields below should be replaced with
    /// their real RPC / reference-data initialization.
    pub async fn new_v31(
        artifact: &EcosystemUpgradeArtifact,
        l1_rpc: impl Into<String>,
        gw_rpc: impl Into<String>,
        contracts_commit: Option<&str>,
        representative_era_chain_id: u64,
        zk_token_asset_id: FixedBytes<32>,
    ) -> anyhow::Result<Self> {
        let bridgehub_address = AddressVerifier::address_from_artifact(
            artifact,
            &["deployed_addresses", "bridgehub", "bridgehub_proxy_addr"],
        )?;
        let bytecode_verifier = BytecodeVerifier::init_v31(contracts_commit).await?;
        let network_verifier =
            NetworkVerifier::new_v31(l1_rpc.into(), gw_rpc.into(), representative_era_chain_id)
                .await?;
        let address_verifier = AddressVerifier::new_v31_from_artifact(artifact)?;

        let era_genesis_config =
            GenesisConfig::init_v31(GenesisConfigKind::Era, contracts_commit).await?;
        let zksync_os_genesis_config =
            GenesisConfig::init_v31(GenesisConfigKind::ZksyncOs, contracts_commit).await?;

        Ok(Self {
            testnet_contracts: false,
            bridgehub_address,
            address_verifier,
            bytecode_verifier,
            network_verifier,
            era_genesis_config,
            zksync_os_genesis_config,
            fee_param_verifier: FeeParamVerifier::empty(),
            gateway_bridgehub_address: L2_BRIDGEHUB_ADDR,
            representative_era_chain_id: Some(representative_era_chain_id),
            zk_token_asset_id,
        })
    }

    pub(crate) fn genesis_config_for_ctm(&self, flavor: CtmFlavor) -> &GenesisConfig {
        match flavor {
            CtmFlavor::Era => &self.era_genesis_config,
            CtmFlavor::ZksyncOs => &self.zksync_os_genesis_config,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct GenesisConfig {
    pub genesis_root: String,
    #[serde(default)]
    pub genesis_rollup_leaf_index: Option<u64>,
    #[serde(default)]
    pub genesis_batch_commitment: Option<String>,
}

impl GenesisConfig {
    pub async fn init_v31(
        kind: GenesisConfigKind,
        contracts_commit: Option<&str>,
    ) -> anyhow::Result<Self> {
        if let Some(contracts_commit) = contracts_commit {
            return Self::init_v31_from_github(kind, contracts_commit).await;
        }

        Self::init_v31_from_local(kind)
    }

    fn init_v31_from_local(kind: GenesisConfigKind) -> anyhow::Result<Self> {
        let path = repo_relative_path(kind.local_path());
        let data = fs::read_to_string(&path)
            .map_err(|e| anyhow::anyhow!("failed to read {}: {e}", path.display()))?;
        serde_json::from_str(&data)
            .map_err(|e| anyhow::anyhow!("failed to parse {}: {e}", path.display()))
    }

    async fn init_v31_from_github(kind: GenesisConfigKind, commit: &str) -> anyhow::Result<Self> {
        let path = kind.local_path();
        let data = get_contents_from_github(commit, "matter-labs/era-contracts", path).await;
        serde_json::from_str(&data).map_err(|e| {
            anyhow::anyhow!("failed to parse {path} from matter-labs/era-contracts@{commit}: {e}")
        })
    }
}

#[derive(Default)]
pub(crate) struct VerificationResult {
    pub(crate) result: String,
    pub(crate) warnings: u64,
    pub(crate) errors: u64,
}

impl VerificationResult {
    pub(crate) fn print_info(&self, info: &str) {
        println!("{}", info);
    }

    pub(crate) fn report_ok(&self, info: &str) {
        println!("{} {}", "[OK]: ".green(), info);
    }

    pub(crate) fn report_warn(&mut self, warn: &str) {
        self.warnings += 1;
        println!("{} {}", "[WARN]:".yellow(), warn);
    }

    pub(crate) fn report_error(&mut self, error: &str) {
        self.errors += 1;
        println!("{} {}", "[ERROR]:".red(), error);
    }

    pub(crate) fn ensure_success(&self) -> anyhow::Result<()> {
        if self.errors > 0 {
            anyhow::bail!(
                "verify-upgrade failed with {} error(s) and {} warning(s)",
                self.errors,
                self.warnings
            );
        }

        Ok(())
    }

    #[track_caller]
    pub(crate) fn expect_address(
        &mut self,
        verifiers: &Verifiers,
        address: &Address,
        expected: &str,
    ) -> bool {
        let expected_address = verifiers.address_verifier.name_to_address.get(expected);
        match expected_address {
            Some(expected_address) => {
                if expected_address == address {
                    true
                } else {
                    self.report_error(&format!(
                        "Expected {} to be {} address - but got address {} at {}",
                        expected,
                        address,
                        expected_address,
                        Location::caller()
                    ));
                    false
                }
            }
            None => {
                self.report_error(&format!(
                    "Expected contract {} doesn't have any address set at {}",
                    expected,
                    Location::caller()
                ));
                false
            }
        }
    }

    #[track_caller]
    pub(crate) fn expect_zk_bytecode(
        &mut self,
        verifiers: &Verifiers,
        bytecode_hash: &FixedBytes<32>,
        expected: &str,
    ) {
        match verifiers
            .bytecode_verifier
            .zk_bytecode_hash_to_file(bytecode_hash)
        {
            Some(file_name) if file_name == expected => {
                // All good.
            }
            Some(file_name) => {
                self.report_error(&format!(
                    "Expected bytecode {}, got {} at {}",
                    expected,
                    file_name,
                    Location::caller()
                ));
            }
            None => {
                self.report_warn(&format!(
                    "Cannot verify bytecode hash: {} - expected {} at {}",
                    bytecode_hash,
                    expected,
                    Location::caller()
                ));
            }
        }
    }

    /// Verifies the deployed bytecode of a contract.
    pub(crate) async fn expect_deployed_bytecode(
        &mut self,
        verifiers: &Verifiers,
        address: &Address,
        expected_file: &str,
    ) {
        let deployed_bytecode = verifiers
            .network_verifier
            .get_bytecode_hash_at(address)
            .await;
        let deployed_file = verifiers
            .bytecode_verifier
            .evm_deployed_bytecode_hash_to_file(&deployed_bytecode);

        if let Some(deployed_file) = deployed_file {
            if deployed_file != expected_file {
                self.report_error(&format!(
                    "Bytecode from wrong file: Expected {} got {} at {}",
                    expected_file,
                    deployed_file,
                    Location::caller()
                ));
                return;
            }
            self.report_ok(&format!("{} at {}", expected_file, address));
        } else if deployed_bytecode == FixedBytes::<32>::ZERO {
            self.report_error(&format!(
                "No bytecode at address {}: Expected {} at {}",
                address,
                expected_file,
                Location::caller()
            ));
        } else {
            // The address has bytecode but its keccak doesn't match any known
            // hash from `AllContractsHashes.json`. The most common cause is
            // Solidity `immutable` constructor args being substituted into
            // the deployed code, so the runtime hash differs from the
            // compile-time hash.
            self.report_error(&format!(
                "Bytecode hash mismatch at address {}: Expected {} at {}",
                address,
                expected_file,
                Location::caller()
            ));
        }
    }

    pub(crate) fn expect_create2_params(
        &mut self,
        verifiers: &Verifiers,
        address: &Address,
        expected_constructor_params: impl AsRef<[u8]>,
        expected_file: &str,
    ) {
        self.expect_create2_params_internal(
            verifiers,
            address,
            expected_constructor_params.as_ref(),
            expected_file,
            true,
        );
    }

    pub(crate) fn expect_create2_params_internal(
        &mut self,
        verifiers: &Verifiers,
        address: &Address,
        expected_constructor_params: &[u8],
        expected_file: &str,
        report_ok: bool,
    ) -> bool {
        let deployed_file = match verifiers
            .network_verifier
            .create2_known_bytecodes
            .get(address)
        {
            Some(file) => file,
            None => {
                self.report_error(&format!(
                    "Address {:#?} {} is not present in the create2 deployments",
                    address, expected_file
                ));
                return false;
            }
        };

        if deployed_file != expected_file {
            self.report_error(&format!(
                "Bytecode from wrong file: Expected {} got {} at {}",
                expected_file,
                deployed_file,
                Location::caller()
            ));
            return false;
        }

        // Safe unwrap because deployed file and constructor params are added at the same time.
        let constructor_params = verifiers
            .network_verifier
            .create2_constructor_params
            .get(address)
            .expect("Constructor params must exist if create2 deployment exists");

        if constructor_params.as_slice() != expected_constructor_params {
            self.report_error(&format!(
                "Invalid constructor params for address {} ({}): Expected {} got {} at {}",
                address,
                expected_file,
                hex::encode(expected_constructor_params),
                hex::encode(constructor_params),
                Location::caller()
            ));
            return false;
        }

        if report_ok {
            self.report_ok(&format!("{} at {}", expected_file, address));
        }
        true
    }

    /// Verifies create2 parameters for a proxy contract that uses a separate implementation.
    pub(crate) async fn expect_create2_params_proxy_with_bytecode(
        &mut self,
        verifiers: &Verifiers,
        address: &Address,
        expected_init_params: impl AsRef<[u8]>,
        expected_initial_admin: Address,
        expected_impl_constructor_params: impl AsRef<[u8]>,
        expected_file: &str,
    ) {
        let transparent_proxy_key = FixedBytes::from_hex(
            "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc",
        )
        .expect("Invalid transparent proxy key hex literal");

        let storage = verifiers
            .network_verifier
            .storage_at(address, &transparent_proxy_key)
            .await;
        // Skip the first 12 bytes to extract the address.
        let implementation_address = Address::from_slice(&storage[12..]);

        let call = transparentProxyConstructorCall::new((
            implementation_address,
            expected_initial_admin,
            Bytes::copy_from_slice(expected_init_params.as_ref()),
        ));
        let mut constructor_params = Vec::new();
        call.abi_encode_raw(&mut constructor_params);

        let is_proxy = self.expect_create2_params_internal(
            verifiers,
            address,
            &constructor_params,
            "l1-contracts/TransparentUpgradeableProxy",
            false,
        );

        if !is_proxy {
            // Error has already been reported.
            return;
        }

        self.expect_create2_params(
            verifiers,
            &implementation_address,
            expected_impl_constructor_params,
            expected_file,
        );
    }
}

impl Display for VerificationResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.errors > 0 {
            write!(
                f,
                "{} errors: {}, warnings: {} - result: {}",
                "ERROR".red(),
                self.errors,
                self.warnings,
                self.result
            )
        } else if self.warnings > 0 {
            write!(
                f,
                "{} warnings: {} - result: {}",
                "WARN".yellow(),
                self.warnings,
                self.result
            )
        } else {
            write!(f, "{} - result: {}", "OK".green(), self.result)
        }
    }
}
