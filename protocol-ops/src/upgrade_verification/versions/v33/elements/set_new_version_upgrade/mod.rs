//! `setNewVersionUpgrade` deep payload verification.
//!
//! Decodes `setNewVersionUpgrade(diamondCut, …).diamondCut.initCalldata` as
//! `DefaultUpgrade.upgrade(ProposedUpgrade)` and validates the entire
//! `ProposedUpgrade` payload — static fields, the L1→L2 upgrade tx, the
//! `forceDeployAndUpgrade(Universal)` inner call, factory deps, and the
//! `IL2V32Upgrade.upgrade` arguments.
//!
//! The flavor split lives in submodules:
//! - [`era`] — Era-VM expected force-deployments, `L2ChainAssetHandler` input
//!   shape, Era factory-dep set, and the Era `forceDeployAndUpgrade` orchestrator.
//! - [`zksync_os`] — ZKsync OS expected force-deployments, deployed-bytecode-info
//!   decoding, ZKsync OS factory-dep set, and the ZKsync OS
//!   `forceDeployAndUpgradeUniversal` orchestrator.
//!
//! This module owns the shared `sol!` types (re-exported under the module
//! path for external consumers like `governance_stage_calls`), the
//! `ProposedUpgrade` impl that dispatches by flavor, `verify_factory_deps`,
//! and `verify_l2_upgrade_inner_calldata` (used by both flavors).

use alloy::{
    hex,
    primitives::{Address, FixedBytes, U256},
    sol,
    sol_types::{SolCall, SolValue},
};
use std::collections::HashSet;

use crate::upgrade_verification::{
    artifacts::CtmFlavor,
    constants::{
        L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR, L2_UPGRADE_GAS_LIMIT,
        L2_UPGRADE_GAS_PER_PUBDATA_BYTE_LIMIT, ZKSYNC_OS_SYSTEM_UPGRADE_TX_TYPE,
    },
    verifiers::{VerificationResult, Verifiers},
};

use super::{fixed_force_deployment::FixedForceDeploymentsData, protocol_version::ProtocolVersion};

mod zksync_os;

sol! {
    #[derive(Debug)]
    enum Action {
        Add,
        Replace,
        Remove
    }

    #[derive(Debug)]
    struct FacetCut {
        address facet;
        Action action;
        bool isFreezable;
        bytes4[] selectors;
    }

    #[derive(Debug)]
    struct DiamondCutData {
        FacetCut[] facetCuts;
        address initAddress;
        bytes initCalldata;
    }

    function setNewVersionUpgrade(
        DiamondCutData diamondCut,
        uint256 oldProtocolVersion,
        uint256 oldProtocolVersionDeadline,
        uint256 newProtocolVersion,
        address verifier
    );

    #[derive(Debug)]
    struct VerifierParams {
        bytes32 recursionNodeLevelVkHash;
        bytes32 recursionLeafLevelVkHash;
        bytes32 recursionCircuitsSetVksHash;
    }

    #[derive(Debug)]
    struct L2CanonicalTransaction {
        uint256 txType;
        uint256 from;
        uint256 to;
        uint256 gasLimit;
        uint256 gasPerPubdataByteLimit;
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        uint256 paymaster;
        uint256 nonce;
        uint256 value;
        // In the future, we might want to add some
        // new fields to the struct. The `txData` struct
        // is to be passed to account and any changes to its structure
        // would mean a breaking change to these accounts. To prevent this,
        // we should keep some fields as "reserved"
        // It is also recommended that their length is fixed, since
        // it would allow easier proof integration (in case we will need
        // some special circuit for preprocessing transactions)
        uint256[4] reserved;
        bytes data;
        bytes signature;
        uint256[] factoryDeps;
        bytes paymasterInput;
        // Reserved dynamic type for the future use-case. Using it should be avoided,
        // But it is still here, just in case we want to enable some additional functionality
        bytes reservedDynamic;
    }

    #[derive(Debug)]
    struct ProposedUpgrade {
        L2CanonicalTransaction l2ProtocolUpgradeTx;
        bytes32 bootloaderHash;
        bytes32 defaultAccountHash;
        bytes32 evmEmulatorHash;
        address verifier;
        VerifierParams verifierParams;
        bytes l1ContractsUpgradeCalldata;
        bytes postUpgradeCalldata;
        uint256 upgradeTimestamp;
        uint256 newProtocolVersion;
    }

    #[derive(Debug)]
    function upgrade(ProposedUpgrade calldata _proposedUpgrade);

    interface IComplexUpgrader {
        #[derive(Debug, PartialEq, Eq)]
        enum ContractUpgradeType {
            EraForceDeployment,
            ZKsyncOSSystemProxyUpgrade,
            ZKsyncOSUnsafeForceDeployment
        }

        #[derive(Debug)]
        struct ForceDeployment {
            bytes32 bytecodeHash;
            address newAddress;
            bool callConstructor;
            uint256 value;
            bytes input;
        }

        #[derive(Debug)]
        struct UniversalContractUpgradeInfo {
            ContractUpgradeType upgradeType;
            bytes deployedBytecodeInfo;
            address newAddress;
        }

        function forceDeployAndUpgrade(
            ForceDeployment[] calldata _forceDeployments,
            address _delegateTo,
            bytes calldata _calldata
        ) external payable;

        function forceDeployAndUpgradeUniversal(
            UniversalContractUpgradeInfo[] calldata _forceDeployments,
            address _delegateTo,
            bytes calldata _calldata
        ) external payable;
    }

    interface IL2V32Upgrade {
        function upgrade(
            bool _isZKsyncOS,
            address _ctmDeployer,
            bytes calldata _fixedForceDeploymentsData,
            bytes calldata _additionalForceDeploymentsData
        ) external;
    }

    #[sol(rpc)]
    contract BytecodesSupplier {
        mapping(bytes32 bytecodeHash => uint256 blockNumber) public publishingBlock;
        mapping(bytes32 bytecodeHash => uint256 blockNumber) public evmPublishingBlock;
    }
}

/// Selects which `BytecodesSupplier` mapping (and which bytecode-verifier
/// lookup table) to consult for a factoryDep hash. Era L2 uses ZK bytecodes;
/// ZKsync OS L2 uses EVM-shaped bytecodes.
#[derive(Debug, Clone, Copy)]
pub(super) enum FactoryDepHashKind {
    EraZkBytecode,
    ZksyncOsEvmBytecode,
}

impl ProposedUpgrade {
    /// Top-level entry: dispatches `verify_static_fields` (bytecode hashes
    /// per flavor + empty-field invariants) and `verify_l2_protocol_upgrade_tx`
    /// (canonical L2 tx shape + inner `forceDeployAndUpgrade(Universal)` walk).
    pub async fn verify_v33_template(
        &self,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
        expected_new_protocol_version: U256,
        expected_fixed_force_deployments_data: &str,
        bytecodes_supplier_addr: Option<Address>,
        ctm_flavor: CtmFlavor,
    ) -> anyhow::Result<usize> {
        result.print_info("== DefaultUpgrade ProposedUpgrade ==");
        let initial_error_count = result.errors;
        let expected_version = ProtocolVersion::from(expected_new_protocol_version);

        self.verify_static_fields(result, expected_new_protocol_version, ctm_flavor);
        self.verify_l2_protocol_upgrade_tx(
            verifiers,
            result,
            expected_version,
            expected_fixed_force_deployments_data,
            bytecodes_supplier_addr,
            ctm_flavor,
        )
        .await?;

        let new_errors = (result.errors - initial_error_count) as usize;
        if new_errors == 0 {
            result.report_ok("DefaultUpgrade ProposedUpgrade matches v33 template");
        }
        Ok(new_errors)
    }

    fn verify_static_fields(
        &self,
        result: &mut VerificationResult,
        expected_new_protocol_version: U256,
        ctm_flavor: CtmFlavor,
    ) {
        match ctm_flavor {
            CtmFlavor::ZksyncOs => {
                expect_zero_bytecode_hash(result, &self.bootloaderHash, "ZKsync OS bootloaderHash");
                expect_zero_bytecode_hash(
                    result,
                    &self.defaultAccountHash,
                    "ZKsync OS defaultAccountHash",
                );
                expect_zero_bytecode_hash(
                    result,
                    &self.evmEmulatorHash,
                    "ZKsync OS evmEmulatorHash",
                );
            }
        }

        if self.verifier != Address::ZERO {
            result.report_error(&format!(
                "ProposedUpgrade verifier must be zero, got {}",
                self.verifier
            ));
        }

        let zero_hash = FixedBytes::<32>::ZERO;
        if self.verifierParams.recursionNodeLevelVkHash != zero_hash
            || self.verifierParams.recursionLeafLevelVkHash != zero_hash
            || self.verifierParams.recursionCircuitsSetVksHash != zero_hash
        {
            result.report_error("ProposedUpgrade verifier params must be empty");
        }

        if !self.l1ContractsUpgradeCalldata.is_empty() {
            result.report_error("ProposedUpgrade l1ContractsUpgradeCalldata must be empty for v33");
        }

        if !self.postUpgradeCalldata.is_empty() {
            result.report_error("ProposedUpgrade postUpgradeCalldata must be empty for v33");
        }

        if self.upgradeTimestamp != U256::default() {
            result.report_error("ProposedUpgrade upgradeTimestamp must be zero");
        }

        if self.newProtocolVersion != expected_new_protocol_version {
            result.report_error(&format!(
                "ProposedUpgrade new protocol version mismatch: expected {}, got {}",
                expected_new_protocol_version, self.newProtocolVersion
            ));
        }
    }

    /// Validates the canonical L2 tx shape, then dispatches strictly on the
    /// CTM flavor: Era expects `(txType=254, data=forceDeployAndUpgrade)`,
    /// ZKsync OS expects `(txType=126, data=forceDeployAndUpgradeUniversal)`.
    /// Mismatched `(flavor, txType)` or `(flavor, inner-data selector)` pairs
    /// are rejected explicitly rather than via decode failure.
    #[allow(clippy::too_many_arguments)]
    async fn verify_l2_protocol_upgrade_tx(
        &self,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
        expected_version: ProtocolVersion,
        expected_fixed_force_deployments_data: &str,
        bytecodes_supplier_addr: Option<Address>,
        ctm_flavor: CtmFlavor,
    ) -> anyhow::Result<()> {
        let tx = &self.l2ProtocolUpgradeTx;

        if tx.from != U256::from_be_slice(L2_FORCE_DEPLOYER_ADDR.as_slice()) {
            result.report_error(&format!(
                "Invalid L2 upgrade tx sender: expected {L2_FORCE_DEPLOYER_ADDR}, got {}",
                tx.from
            ));
        }
        if tx.to != U256::from_be_slice(L2_COMPLEX_UPGRADER_ADDR.as_slice()) {
            result.report_error(&format!(
                "Invalid L2 upgrade tx target: expected {L2_COMPLEX_UPGRADER_ADDR}, got {}",
                tx.to
            ));
        }
        if tx.gasLimit != U256::from(L2_UPGRADE_GAS_LIMIT) {
            result.report_error(&format!(
                "Invalid L2 upgrade tx gasLimit: expected {L2_UPGRADE_GAS_LIMIT}, got {}",
                tx.gasLimit
            ));
        }
        if tx.gasPerPubdataByteLimit != U256::from(L2_UPGRADE_GAS_PER_PUBDATA_BYTE_LIMIT) {
            result.report_error(&format!(
                "Invalid L2 upgrade tx gasPerPubdataByteLimit: expected {L2_UPGRADE_GAS_PER_PUBDATA_BYTE_LIMIT}, got {}",
                tx.gasPerPubdataByteLimit
            ));
        }
        if tx.maxFeePerGas != U256::ZERO {
            result.report_error("Invalid L2 upgrade tx maxFeePerGas");
        }
        if tx.maxPriorityFeePerGas != U256::ZERO {
            result.report_error("Invalid L2 upgrade tx maxPriorityFeePerGas");
        }
        if tx.paymaster != U256::ZERO {
            result.report_error("Invalid L2 upgrade tx paymaster");
        }
        if tx.nonce != U256::from(expected_version.minor) {
            result.report_error(&format!(
                "L2 upgrade tx nonce must be the minor protocol version: expected {}, got {}",
                expected_version.minor, tx.nonce
            ));
        }
        if tx.value != U256::ZERO {
            result.report_error("Invalid L2 upgrade tx value");
        }
        if tx.reserved != [U256::ZERO; 4] {
            result.report_error("Invalid L2 upgrade tx reserved fields");
        }
        if !tx.signature.is_empty() {
            result.report_error("Invalid L2 upgrade tx signature");
        }
        if !tx.paymasterInput.is_empty() {
            result.report_error("Invalid L2 upgrade tx paymasterInput");
        }
        if !tx.reservedDynamic.is_empty() {
            result.report_error("Invalid L2 upgrade tx reservedDynamic");
        }

        match ctm_flavor {
            CtmFlavor::ZksyncOs => {
                if tx.txType != U256::from(ZKSYNC_OS_SYSTEM_UPGRADE_TX_TYPE) {
                    result.report_error(&format!(
                        "ZKsync OS L2 upgrade tx must use txType {ZKSYNC_OS_SYSTEM_UPGRADE_TX_TYPE}, got {}",
                        tx.txType
                    ));
                }
                let decoded = match IComplexUpgrader::forceDeployAndUpgradeUniversalCall::abi_decode(
                    &tx.data,
                ) {
                    Ok(decoded) => decoded,
                    Err(err) => {
                        result.report_error(&format!(
                            "ZKsync OS L2 upgrade tx data must decode as forceDeployAndUpgradeUniversal: {err}"
                        ));
                        return Ok(());
                    }
                };
                verify_factory_deps(
                    verifiers,
                    result,
                    &tx.factoryDeps,
                    zksync_os::EXPECTED_V33_ZKSYNC_OS_BYTECODES,
                    "ZKsync OS",
                    bytecodes_supplier_addr,
                    FactoryDepHashKind::ZksyncOsEvmBytecode,
                )
                .await;
                zksync_os::verify_zksync_os_force_deploy_and_upgrade(
                    verifiers,
                    result,
                    &decoded,
                    expected_fixed_force_deployments_data,
                )
                .await?;
                result.report_ok("Decoded ZKsync OS forceDeployAndUpgradeUniversal L2 upgrade tx");
            }
        }
        Ok(())
    }
}

/// Calldata-only check that `factoryDeps[]` matches the expected v33 set, plus
/// an optional live-RPC check that each bytecode was actually published to the
/// `BytecodesSupplier` (required for the L2 sequencer to fetch it during the
/// upgrade tx). When `bytecodes_supplier_addr` is `None` the supplier round-trip
/// is skipped — set-membership against `expected_bytecodes` still runs.
async fn verify_factory_deps(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    factory_deps: &[U256],
    expected_bytecodes: &[&str],
    label: &str,
    bytecodes_supplier_addr: Option<Address>,
    hash_kind: FactoryDepHashKind,
) {
    let expected_bytecodes: HashSet<&str> = expected_bytecodes.iter().copied().collect();
    let mut actual_bytecodes = HashSet::new();
    let mut errors = 0;

    for dep in factory_deps {
        let dep = fixed_bytes_from_u256(dep);
        match bytecode_hash_to_file(verifiers, &dep, hash_kind) {
            Some(file_name) => {
                if !expected_bytecodes.contains(file_name.as_str()) {
                    errors += 1;
                    result.report_error(&format!(
                        "Unexpected {label} dependency in L2 upgrade tx factoryDeps: {file_name}"
                    ));
                }
                if !actual_bytecodes.insert(file_name.as_str()) {
                    errors += 1;
                    result.report_error(&format!(
                        "Duplicate {label} dependency in L2 upgrade tx factoryDeps: {file_name}"
                    ));
                }
            }
            None => {
                errors += 1;
                result.report_error(&format!(
                    "Unknown {label} bytecode hash in L2 upgrade tx factoryDeps: {}",
                    dep
                ));
            }
        }
    }

    let mut missing_bytecodes = expected_bytecodes
        .difference(&actual_bytecodes)
        .copied()
        .collect::<Vec<_>>();
    missing_bytecodes.sort_unstable();
    if !missing_bytecodes.is_empty() {
        errors += missing_bytecodes.len();
        result.report_error(&format!(
            "Missing {label} dependencies in L2 upgrade tx factoryDeps: {:?}",
            missing_bytecodes
        ));
    }

    if errors == 0 {
        result.report_ok(&format!(
            "{label} L2 upgrade tx factoryDeps match expected v33 dependency set"
        ));
    }

    // Re-add the legacy PUVT `BytecodesSupplier.publishingBlock(hash) != 0`
    // check for every factoryDep when an RPC + supplier address are
    // available. This is intentionally a post-calldata check: it requires
    // reading on-chain state from a live L1 RPC with the v33 prepare bundles
    // already replayed.
    if let Some(supplier_addr) = bytecodes_supplier_addr {
        let supplier =
            BytecodesSupplier::new(supplier_addr, verifiers.network_verifier.get_l1_provider());
        let mut publish_errors = 0usize;
        for dep in factory_deps {
            let dep = fixed_bytes_from_u256(dep);
            let publishing_block = match hash_kind {
                FactoryDepHashKind::EraZkBytecode => supplier.publishingBlock(dep).call().await,
                FactoryDepHashKind::ZksyncOsEvmBytecode => {
                    supplier.evmPublishingBlock(dep).call().await
                }
            };
            match publishing_block {
                Ok(block) if block != U256::ZERO => {}
                Ok(_) => {
                    publish_errors += 1;
                    let dep_label = bytecode_hash_to_file(verifiers, &dep, hash_kind)
                        .cloned()
                        .unwrap_or_else(|| format!("0x{dep:x}"));
                    result.report_error(&format!(
                        "BytecodesSupplier has not published {label} factoryDep {dep_label}"
                    ));
                }
                Err(err) => {
                    publish_errors += 1;
                    let mapping_name = match hash_kind {
                        FactoryDepHashKind::EraZkBytecode => "publishingBlock",
                        FactoryDepHashKind::ZksyncOsEvmBytecode => "evmPublishingBlock",
                    };
                    result.report_error(&format!(
                        "BytecodesSupplier.{mapping_name} call failed for {label} factoryDep 0x{dep:x}: {err}"
                    ));
                }
            }
        }
        if publish_errors == 0 {
            result.report_ok(&format!(
                "All {} {label} L2 upgrade tx factoryDeps are published in BytecodesSupplier",
                factory_deps.len()
            ));
        }
    }
}

/// Decodes the `IL2V32Upgrade.upgrade(...)` inner calldata from the
/// `forceDeployAndUpgrade(Universal)` `_calldata` argument and validates each
/// field. Shared by both Era and ZKsync OS paths — they only differ in the
/// expected value of `_isZKsyncOS`.
pub(super) async fn verify_l2_upgrade_inner_calldata(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    calldata: &[u8],
    expected_is_zksync_os: bool,
    expected_fixed_force_deployments_data: &str,
) -> anyhow::Result<()> {
    use anyhow::Context;
    let decoded = IL2V32Upgrade::upgradeCall::abi_decode(calldata)
        .context("decoding IL2V32Upgrade.upgrade inner calldata")?;

    if decoded._isZKsyncOS != expected_is_zksync_os {
        result.report_error(&format!(
            "IL2V32Upgrade.upgrade _isZKsyncOS mismatch: expected {}, got {}",
            expected_is_zksync_os, decoded._isZKsyncOS
        ));
    }
    result.expect_address(
        verifiers,
        &decoded._ctmDeployer,
        "ctm_deployment_tracker_proxy",
    );

    if !expected_fixed_force_deployments_data.is_empty() {
        let expected = expected_fixed_force_deployments_data
            .strip_prefix("0x")
            .unwrap_or(expected_fixed_force_deployments_data);
        let actual = hex::encode(&decoded._fixedForceDeploymentsData);
        if !actual.eq_ignore_ascii_case(expected) {
            result.report_error(&format!(
                "IL2V32Upgrade.upgrade fixedForceDeploymentsData mismatch. Expected: 0x{}\nReceived: 0x{}",
                expected, actual
            ));
        } else {
            result.report_ok("IL2V32Upgrade.upgrade fixedForceDeploymentsData matches TOML");
        }
    }

    // Decode fixedForceDeploymentsData and verify each field independently so
    // the artifact hex is not merely trusted as a self-referential source of truth.
    result.print_info("-- fixedForceDeploymentsData field verification (inner calldata) --");
    match FixedForceDeploymentsData::abi_decode(&decoded._fixedForceDeploymentsData) {
        Ok(fixed_data) => fixed_data.verify(verifiers, result).await?,
        Err(err) => result.report_error(&format!(
            "Failed to decode IL2V32Upgrade.upgrade fixedForceDeploymentsData: {err}"
        )),
    }

    if !decoded._additionalForceDeploymentsData.is_empty() {
        result.report_error(
            "IL2V32Upgrade.upgrade additionalForceDeploymentsData template must be empty",
        );
    } else {
        result.report_ok("IL2V32Upgrade.upgrade additionalForceDeploymentsData template is empty");
    }

    Ok(())
}

fn fixed_bytes_from_u256(value: &U256) -> FixedBytes<32> {
    FixedBytes::<32>::from_slice(&value.to_be_bytes::<32>())
}

fn bytecode_hash_to_file<'a>(
    verifiers: &'a Verifiers,
    bytecode_hash: &FixedBytes<32>,
    hash_kind: FactoryDepHashKind,
) -> Option<&'a String> {
    match hash_kind {
        FactoryDepHashKind::EraZkBytecode => verifiers
            .bytecode_verifier
            .zk_bytecode_hash_to_file(bytecode_hash),
        FactoryDepHashKind::ZksyncOsEvmBytecode => verifiers
            .bytecode_verifier
            .evm_deployed_bytecode_hash_to_file(bytecode_hash),
    }
}

fn expect_zero_bytecode_hash(
    result: &mut VerificationResult,
    bytecode_hash: &FixedBytes<32>,
    label: &str,
) {
    if *bytecode_hash == FixedBytes::<32>::ZERO {
        result.report_ok(&format!("{label} is zero"));
    } else {
        result.report_error(&format!("{label} must be zero, got {}", bytecode_hash));
    }
}
