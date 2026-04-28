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
use std::panic::Location;

use crate::upgrade_verification::versions::v31::{
    utils::{
        address_from_short_hex, address_verifier::AddressVerifier,
        bytecode_verifier::BytecodeVerifier, fee_param_verifier::FeeParamVerifier,
        get_contents_from_github, network_verifier::NetworkVerifier,
    },
    UpgradeOutput,
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
    pub genesis_config: GenesisConfig,
    pub fee_param_verifier: FeeParamVerifier,
    pub gateway_bridgehub_address: Address,
}

impl Verifiers {
    /// Creates a new `Verifiers` instance.
    pub async fn new(
        testnet_contracts: bool,
        bridgehub_address: impl AsRef<str>,
        era_commit: &str,
        contracts_commit: &str,
        l1_rpc: String,
        gw_rpc: String,
        era_chain_id: u64,
        gateway_chain_id: u64,
        config: &UpgradeOutput,
    ) -> Self {
        let bridgehub_address =
            Address::from_hex(bridgehub_address.as_ref()).expect("Bridgehub address");

        let bytecode_verifier = BytecodeVerifier::init_from_github(contracts_commit).await;
        let network_verifier = NetworkVerifier::new(
            l1_rpc,
            era_chain_id,
            gateway_chain_id,
            gw_rpc,
            &bytecode_verifier,
            config,
            &bridgehub_address,
        )
        .await;

        if testnet_contracts && network_verifier.get_l1_chain_id() == 1 {
            panic!("Testnet contracts are not expected to be deployed on L1 mainnet - you passed --testnet-contracts flag.");
        }

        let address_verifier = AddressVerifier::new(
            bridgehub_address,
            &network_verifier,
            &bytecode_verifier,
            config,
        )
        .await;

        let fee_param_verifier =
            FeeParamVerifier::safe_init(&bridgehub_address, &network_verifier, contracts_commit)
                .await;
        Self {
            testnet_contracts,
            bridgehub_address,
            address_verifier,
            bytecode_verifier,
            network_verifier,
            genesis_config: GenesisConfig::init_from_github(era_commit)
                .await
                .expect("Failed to init"),
            fee_param_verifier,
            gateway_bridgehub_address: address_from_short_hex("10002"),
        }
    }

    /// Fetches extra addresses from the network and appends them to the internal verifier.
    pub async fn append_addresses(&mut self) -> anyhow::Result<()> {
        let info = self
            .network_verifier
            .get_bridgehub_info(self.bridgehub_address)
            .await;

        self.address_verifier
            .add_address(self.bridgehub_address, "bridgehub_proxy");
        self.address_verifier
            .add_address(info.stm_address, "state_transition_manager");
        self.address_verifier
            .add_address(info.transparent_proxy_admin, "transparent_proxy_admin");
        self.address_verifier
            .add_address(info.shared_bridge, "old_shared_bridge_proxy");
        self.address_verifier
            .add_address(info.legacy_bridge, "legacy_erc20_bridge_proxy");
        Ok(())
    }
}

#[derive(Debug, Deserialize)]
pub struct GenesisConfig {
    pub genesis_root: String,
    pub genesis_rollup_leaf_index: u64,
    pub genesis_batch_commitment: String,
}

impl GenesisConfig {
    /// Initializes the genesis configuration from a file on GitHub.
    pub async fn init_from_github(commit: &str) -> anyhow::Result<Self> {
        println!("init from github {}", commit);
        let data = get_contents_from_github(
            commit,
            "matter-labs/zksync-era",
            "etc/env/file_based/genesis.yaml",
        )
        .await;
        serde_yaml::from_str(&data)
            .map_err(|e| anyhow::anyhow!("Failed to parse genesis.yaml: {}", e))
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
        } else {
            self.report_error(&format!(
                "Bytecode at address {} empty: Expected {} at {}",
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
