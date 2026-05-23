use alloy::{
    hex,
    primitives::{keccak256, Address, FixedBytes, U256},
    sol,
    sol_types::{SolCall, SolValue},
};
use anyhow::Context;
use std::collections::{HashMap, HashSet};

use crate::upgrade_verification::{
    artifacts::CtmFlavor,
    verifiers::{VerificationResult, Verifiers},
};

use super::{
    super::utils::apply_l2_to_l1_alias,
    fixed_force_deployment::FixedForceDeploymentsData,
    protocol_version::ProtocolVersion,
};

const L2_FORCE_DEPLOYER_ADDRESS: u32 = 0x8007;
const L2_COMPLEX_UPGRADER_ADDRESS: u32 = 0x800f;
const L2_VERSION_SPECIFIC_UPGRADER_ADDRESS: u32 = 0x10001;
const ERA_SYSTEM_UPGRADE_TX_TYPE: u64 = 254;
const ZKSYNC_OS_SYSTEM_UPGRADE_TX_TYPE: u64 = 126;
const L2_UPGRADE_GAS_LIMIT: u64 = 72_000_000;
const L2_UPGRADE_GAS_PER_PUBDATA_BYTE_LIMIT: u64 = 800;
const L2_V31_UPGRADE_CONTRACT: &str = "l1-contracts/L2V31Upgrade";
const BOOTLOADER_CONTRACT: &str = "Bootloader";
const DEFAULT_ACCOUNT_CONTRACT: &str = "system-contracts/DefaultAccount";
const EVM_EMULATOR_CONTRACT: &str = "EvmEmulator";

// ── L2 address constants (mirrors L2ContractAddresses.sol, BUILT_IN_CONTRACTS_OFFSET=0x10000) ──
const L2_CREATE2_FACTORY_ADDR: u32 = 0x10000;
const L2_SLOAD_CONTRACT_ADDR: u32 = 0x10006;
const L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR: u32 = 0x1000c;
const L2_BRIDGEHUB_ADDR: u32 = 0x10002;
const L2_ASSET_ROUTER_ADDR: u32 = 0x10003;
const L2_NATIVE_TOKEN_VAULT_ADDR: u32 = 0x10004;
const L2_MESSAGE_ROOT_ADDR: u32 = 0x10005;
const L2_WRAPPED_BASE_TOKEN_IMPL_ADDR: u32 = 0x10007;
const L2_INTEROP_ROOT_STORAGE_ADDR: u32 = 0x10008;
const L2_MESSAGE_VERIFICATION_ADDR: u32 = 0x10009;
const L2_CHAIN_ASSET_HANDLER_ADDR: u32 = 0x1000a;
const L2_INTEROP_CENTER_ADDR: u32 = 0x1000d;
const L2_INTEROP_HANDLER_ADDR: u32 = 0x1000e;
const L2_ASSET_TRACKER_ADDR: u32 = 0x1000f;
const GW_ASSET_TRACKER_ADDR: u32 = 0x10010;
const L2_BASE_TOKEN_HOLDER_ADDR: u32 = 0x10011;

/// How to validate the `input` field of an Era force deployment entry.
enum EraFdInput {
    /// input must be empty.
    Empty,
    /// L2ChainAssetHandler: input = abi.encode(l1ChainId, aliasedOwner, bridgehub, assetRouter, messageRoot).
    L2ChainAssetHandler,
}

struct EraExpectedFd {
    address: Address,
    file: &'static str,
    call_constructor: bool,
    input_kind: EraFdInput,
}

/// Expected v31 Era `ForceDeployment[]` passed to `ComplexUpgrader.forceDeployAndUpgrade`.
///
/// Order mirrors the deploy script: system contracts (EraVmSystemContract enum 0..30),
/// then fixed-address core contracts (_fillFixedAddressCoreContracts), then L2V31Upgrade.
fn expected_v31_era_force_deployments() -> Vec<EraExpectedFd> {
    macro_rules! simple {
        ($file:expr, $addr:expr) => {
            EraExpectedFd {
                address: address_from_short_u32($addr),
                file: $file,
                call_constructor: false,
                input_kind: EraFdInput::Empty,
            }
        };
    }
    vec![
        // ── EraVM system contracts (SYSTEM_CONTRACTS_COUNT = 31) ──
        simple!("system-contracts/EmptyContract", 0x0000),
        simple!("Ecrecover", 0x0001),
        simple!("SHA256", 0x0002),
        simple!("Identity", 0x0004),
        simple!("EcAdd", 0x0006),
        simple!("EcMul", 0x0007),
        simple!("EcPairing", 0x0008),
        simple!("Modexp", 0x0005),
        simple!("system-contracts/EmptyContract", 0x8001), // bootloader slot
        simple!("system-contracts/AccountCodeStorage", 0x8002),
        simple!("system-contracts/NonceHolder", 0x8003),
        simple!("system-contracts/KnownCodesStorage", 0x8004),
        simple!("system-contracts/ImmutableSimulator", 0x8005),
        simple!("system-contracts/ContractDeployer", 0x8006),
        simple!("system-contracts/L1Messenger", 0x8008),
        simple!("system-contracts/MsgValueSimulator", 0x8009),
        simple!("l1-contracts/L2BaseTokenEra", 0x800a), // L2BaseToken bytecode is L2BaseTokenEra
        simple!("system-contracts/SystemContext", 0x800b),
        simple!("system-contracts/BootloaderUtilities", 0x800c),
        simple!("EventWriter", 0x800d),
        simple!("system-contracts/Compressor", 0x800e),
        simple!("Keccak256", 0x8010),
        simple!("system-contracts/PubdataChunkPublisher", 0x8011),
        simple!("CodeOracle", 0x8012),
        simple!("EvmGasManager", 0x8013),
        simple!("system-contracts/EvmPredeploysManager", 0x8014),
        simple!("system-contracts/EvmHashesStorage", 0x8015),
        simple!("P256Verify", 0x0100),
        simple!("system-contracts/Create2Factory", L2_CREATE2_FACTORY_ADDR),
        simple!("system-contracts/SloadContract", L2_SLOAD_CONTRACT_ADDR),
        simple!(
            "l1-contracts/SystemContractProxyAdmin",
            L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR
        ),
        // ── Fixed-address core contracts (FIXED_ADDRESS_CORE_CONTRACTS_COUNT = 13) ──
        simple!("l1-contracts/L2Bridgehub", L2_BRIDGEHUB_ADDR),
        simple!("l1-contracts/L2AssetRouter", L2_ASSET_ROUTER_ADDR),
        simple!(
            "l1-contracts/L2NativeTokenVault",
            L2_NATIVE_TOKEN_VAULT_ADDR
        ),
        simple!("l1-contracts/L2MessageRoot", L2_MESSAGE_ROOT_ADDR),
        simple!(
            "l1-contracts/L2WrappedBaseToken",
            L2_WRAPPED_BASE_TOKEN_IMPL_ADDR
        ),
        simple!(
            "l1-contracts/L2MessageVerification",
            L2_MESSAGE_VERIFICATION_ADDR
        ),
        // L2ChainAssetHandler: callConstructor=true, special input
        EraExpectedFd {
            address: address_from_short_u32(L2_CHAIN_ASSET_HANDLER_ADDR),
            file: "l1-contracts/L2ChainAssetHandler",
            call_constructor: true,
            input_kind: EraFdInput::L2ChainAssetHandler,
        },
        simple!(
            "l1-contracts/L2InteropRootStorage",
            L2_INTEROP_ROOT_STORAGE_ADDR
        ),
        simple!("l1-contracts/BaseTokenHolder", L2_BASE_TOKEN_HOLDER_ADDR),
        simple!("l1-contracts/L2AssetTracker", L2_ASSET_TRACKER_ADDR),
        simple!("l1-contracts/InteropCenter", L2_INTEROP_CENTER_ADDR),
        simple!("l1-contracts/InteropHandler", L2_INTEROP_HANDLER_ADDR),
        simple!("l1-contracts/GWAssetTracker", GW_ASSET_TRACKER_ADDR),
        // ── Additional: L2V31Upgrade (the delegate target for this upgrade) ──
        simple!(
            L2_V31_UPGRADE_CONTRACT,
            L2_VERSION_SPECIFIC_UPGRADER_ADDRESS
        ),
    ]
}

/// Validate the full `ForceDeployment[]` array from `ComplexUpgrader.forceDeployAndUpgrade`
/// against the expected v31 list.
async fn verify_v31_era_force_deployments(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    deployments: &[IComplexUpgrader::ForceDeployment],
) -> anyhow::Result<()> {
    let expected = expected_v31_era_force_deployments();
    let mut expected_map: HashMap<Address, EraExpectedFd> =
        expected.into_iter().map(|e| (e.address, e)).collect();

    for deployment in deployments {
        let addr = deployment.newAddress;
        match expected_map.remove(&addr) {
            None => {
                let hash_label = verifiers
                    .bytecode_verifier
                    .zk_bytecode_hash_to_file(&deployment.bytecodeHash)
                    .cloned()
                    .unwrap_or_else(|| format!("unknown hash {}", deployment.bytecodeHash));
                result.report_error(&format!(
                    "Unexpected Era force deployment at {} ({})",
                    addr, hash_label
                ));
            }
            Some(expected_entry) => {
                result.expect_zk_bytecode(verifiers, &deployment.bytecodeHash, expected_entry.file);
                if deployment.callConstructor != expected_entry.call_constructor {
                    result.report_error(&format!(
                        "Era force deployment at {} ({}): callConstructor expected {}, got {}",
                        addr,
                        expected_entry.file,
                        expected_entry.call_constructor,
                        deployment.callConstructor
                    ));
                }
                if deployment.value != U256::ZERO {
                    result.report_error(&format!(
                        "Era force deployment at {} ({}): value must be zero, got {}",
                        addr, expected_entry.file, deployment.value
                    ));
                }
                match expected_entry.input_kind {
                    EraFdInput::Empty => {
                        if !deployment.input.is_empty() {
                            result.report_error(&format!(
                                "Era force deployment at {} ({}): input must be empty",
                                addr, expected_entry.file
                            ));
                        }
                    }
                    EraFdInput::L2ChainAssetHandler => {
                        verify_l2_chain_asset_handler_input(verifiers, result, &deployment.input)
                            .await;
                    }
                }
            }
        }
    }

    let mut missing: Vec<_> = expected_map
        .values()
        .map(|e| format!("{} at {}", e.file, e.address))
        .collect();
    missing.sort();
    for m in &missing {
        result.report_error(&format!("Missing Era force deployment: {}", m));
    }

    if missing.is_empty() {
        result.report_ok("All Era force deployments match the expected v31 list");
    }
    Ok(())
}

/// Verify the ABI-encoded constructor input for the L2ChainAssetHandler force deployment.
///
/// Expected: abi.encode(l1ChainId, aliasedOwner, L2_BRIDGEHUB_ADDR, L2_ASSET_ROUTER_ADDR, L2_MESSAGE_ROOT_ADDR).
async fn verify_l2_chain_asset_handler_input(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    input: &[u8],
) {
    type Decoded = (U256, Address, Address, Address, Address);
    let (l1_chain_id, aliased_owner, l2_bridgehub, l2_asset_router, l2_message_root) =
        match Decoded::abi_decode(input) {
            Ok(v) => v,
            Err(err) => {
                result.report_error(&format!(
                    "L2ChainAssetHandler force deployment input: failed to ABI-decode: {err}"
                ));
                return;
            }
        };

    match verifiers.network_verifier.try_get_l1_chain_id().await {
        Ok(expected_chain_id) => {
            if l1_chain_id != U256::from(expected_chain_id) {
                result.report_error(&format!(
                    "L2ChainAssetHandler input l1ChainId: expected {expected_chain_id}, got {l1_chain_id}"
                ));
            } else {
                result.report_ok("L2ChainAssetHandler input l1ChainId matches RPC");
            }
        }
        Err(err) => result.report_warn(&format!(
            "Cannot verify L2ChainAssetHandler input l1ChainId: {err}"
        )),
    }

    match verifiers
        .address_verifier
        .get_by_name("aliased_protocol_upgrade_handler_proxy")
    {
        Some(expected) => {
            if aliased_owner == expected {
                result
                    .report_ok("L2ChainAssetHandler input aliasedOwner matches aliased governance");
            } else {
                result.report_error(&format!(
                    "L2ChainAssetHandler input aliasedOwner: expected {expected}, got {aliased_owner}"
                ));
            }
        }
        None => {
            // Fallback: try to derive alias from any governance address in the book.
            let governance = verifiers.address_verifier.get_by_name("governance");
            let puh = verifiers
                .address_verifier
                .get_by_name("protocol_upgrade_handler_proxy");
            if let Some(gov_addr) = governance.or(puh) {
                let expected_aliased = apply_l2_to_l1_alias(Address(*gov_addr));
                if aliased_owner == expected_aliased {
                    result.report_ok(
                        "L2ChainAssetHandler input aliasedOwner matches derived alias of governance",
                    );
                } else {
                    result.report_error(&format!(
                        "L2ChainAssetHandler input aliasedOwner: derived alias {expected_aliased}, got {aliased_owner}"
                    ));
                }
            } else {
                result.report_warn(&format!(
                    "L2ChainAssetHandler input aliasedOwner (not verified, governance address missing from address book): {aliased_owner}"
                ));
            }
        }
    }

    let expected_bridgehub = address_from_short_u32(L2_BRIDGEHUB_ADDR);
    if l2_bridgehub != expected_bridgehub {
        result.report_error(&format!(
            "L2ChainAssetHandler input l2Bridgehub: expected {expected_bridgehub}, got {l2_bridgehub}"
        ));
    }
    let expected_asset_router = address_from_short_u32(L2_ASSET_ROUTER_ADDR);
    if l2_asset_router != expected_asset_router {
        result.report_error(&format!(
            "L2ChainAssetHandler input l2AssetRouter: expected {expected_asset_router}, got {l2_asset_router}"
        ));
    }
    let expected_message_root = address_from_short_u32(L2_MESSAGE_ROOT_ADDR);
    if l2_message_root != expected_message_root {
        result.report_error(&format!(
            "L2ChainAssetHandler input l2MessageRoot: expected {expected_message_root}, got {l2_message_root}"
        ));
    }
}

/// ZKsync OS upgrade type — mirrors IComplexUpgrader.ContractUpgradeType.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum ZksyncOSUpgradeType {
    SystemProxyUpgrade,
    UnsafeForceDeployment,
}

struct ZksyncOSExpectedFd {
    address: Address,
    file: &'static str,
    upgrade_type: ZksyncOSUpgradeType,
}

/// Expected v31 ZKsyncOS `UniversalContractUpgradeInfo[]` passed to
/// `ComplexUpgrader.forceDeployAndUpgradeUniversal` — excludes the L2V31Upgrade delegate-target
/// entry, which is validated separately by `verify_zksync_os_l2_v31_deployment`.
fn expected_v31_zksync_os_force_deployments() -> Vec<ZksyncOSExpectedFd> {
    macro_rules! proxy {
        ($file:expr, $addr:expr) => {
            ZksyncOSExpectedFd {
                address: address_from_short_u32($addr),
                file: $file,
                upgrade_type: ZksyncOSUpgradeType::SystemProxyUpgrade,
            }
        };
    }
    macro_rules! unsafe_fd {
        ($file:expr, $addr:expr) => {
            ZksyncOSExpectedFd {
                address: address_from_short_u32($addr),
                file: $file,
                upgrade_type: ZksyncOSUpgradeType::UnsafeForceDeployment,
            }
        };
    }
    vec![
        // ── Fixed-address core contracts (getFixedAddressCoreContracts, 13 entries) ──
        proxy!("l1-contracts/L2Bridgehub", L2_BRIDGEHUB_ADDR),
        proxy!("l1-contracts/L2AssetRouter", L2_ASSET_ROUTER_ADDR),
        proxy!(
            "l1-contracts/L2NativeTokenVaultZKOS",
            L2_NATIVE_TOKEN_VAULT_ADDR
        ),
        proxy!("l1-contracts/L2MessageRoot", L2_MESSAGE_ROOT_ADDR),
        // L2WrappedBaseToken sits directly as the implementation — not behind a proxy.
        unsafe_fd!(
            "l1-contracts/L2WrappedBaseToken",
            L2_WRAPPED_BASE_TOKEN_IMPL_ADDR
        ),
        proxy!(
            "l1-contracts/L2MessageVerification",
            L2_MESSAGE_VERIFICATION_ADDR
        ),
        proxy!(
            "l1-contracts/L2ChainAssetHandler",
            L2_CHAIN_ASSET_HANDLER_ADDR
        ),
        proxy!(
            "l1-contracts/L2InteropRootStorage",
            L2_INTEROP_ROOT_STORAGE_ADDR
        ),
        proxy!("l1-contracts/BaseTokenHolder", L2_BASE_TOKEN_HOLDER_ADDR),
        proxy!("l1-contracts/L2AssetTracker", L2_ASSET_TRACKER_ADDR),
        proxy!("l1-contracts/InteropCenter", L2_INTEROP_CENTER_ADDR),
        proxy!("l1-contracts/InteropHandler", L2_INTEROP_HANDLER_ADDR),
        proxy!("l1-contracts/GWAssetTracker", GW_ASSET_TRACKER_ADDR),
        // ── ZKsync-OS system contracts (getZKsyncOSExtraSystemContracts, 3 entries) ──
        proxy!("l1-contracts/L2BaseTokenZKOS", 0x800a), // L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR
        proxy!("l1-contracts/L1MessengerZKOS", 0x8008), // L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR
        proxy!("l1-contracts/SystemContext", 0x800b),   // L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR
        // ── ProxyAdmin (_buildZKsyncOSProxyAdminEntry) ──
        unsafe_fd!(
            "l1-contracts/SystemContractProxyAdmin",
            L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR
        ),
    ]
}

/// Validate all entries of `UniversalContractUpgradeInfo[]` except the L2V31Upgrade delegate-target
/// (which is already validated by `verify_zksync_os_l2_v31_deployment`).
fn verify_v31_zksync_os_force_deployments(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    deployments: &[IComplexUpgrader::UniversalContractUpgradeInfo],
    delegate_to: Address,
) {
    let expected = expected_v31_zksync_os_force_deployments();
    let mut expected_map: HashMap<Address, ZksyncOSExpectedFd> =
        expected.into_iter().map(|e| (e.address, e)).collect();

    for deployment in deployments {
        // Skip the L2V31Upgrade delegate-target; already validated elsewhere.
        if deployment.newAddress == delegate_to {
            continue;
        }

        let addr = deployment.newAddress;
        match expected_map.remove(&addr) {
            None => {
                result.report_error(&format!("Unexpected ZKsyncOS force deployment at {}", addr));
            }
            Some(expected_entry) => {
                // Verify upgradeType.
                let actual_upgrade_type = if deployment.upgradeType
                    == IComplexUpgrader::ContractUpgradeType::ZKsyncOSSystemProxyUpgrade
                {
                    ZksyncOSUpgradeType::SystemProxyUpgrade
                } else if deployment.upgradeType
                    == IComplexUpgrader::ContractUpgradeType::ZKsyncOSUnsafeForceDeployment
                {
                    ZksyncOSUpgradeType::UnsafeForceDeployment
                } else {
                    result.report_error(&format!(
                        "ZKsyncOS force deployment at {} ({}): unexpected upgradeType {:?}",
                        addr, expected_entry.file, deployment.upgradeType
                    ));
                    continue;
                };
                if actual_upgrade_type != expected_entry.upgrade_type {
                    result.report_error(&format!(
                        "ZKsyncOS force deployment at {} ({}): upgradeType expected {:?}, got {:?}",
                        addr, expected_entry.file, expected_entry.upgrade_type, actual_upgrade_type
                    ));
                }

                // Verify deployedBytecodeInfo -> file.
                verify_zksync_os_deployed_bytecode_info(
                    verifiers,
                    result,
                    &deployment.deployedBytecodeInfo,
                    expected_entry.file,
                    &format!("{addr}"),
                    expected_entry.upgrade_type,
                );
            }
        }
    }

    let mut missing: Vec<_> = expected_map
        .values()
        .map(|e| format!("{} at {}", e.file, e.address))
        .collect();
    missing.sort();
    for m in &missing {
        result.report_error(&format!("Missing ZKsyncOS force deployment: {}", m));
    }

    if missing.is_empty() {
        result.report_ok(
            "All ZKsyncOS force deployments match the expected v31 list (excluding L2V31Upgrade delegate target)",
        );
    }
}

/// Verify the `deployedBytecodeInfo` of a ZKsyncOS force deployment entry maps to the expected file.
///
/// - `ZKsyncOSUnsafeForceDeployment`: 96-byte triple (blake2s | padding | keccak256); observable at [64..96].
/// - `ZKsyncOSSystemProxyUpgrade`: abi.encode(implInfo_96, proxyInfo_96) = 320 bytes;
///   impl observable (keccak256 of deployed impl bytecode) at [160..192].
fn verify_zksync_os_deployed_bytecode_info(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    bytecode_info: &[u8],
    expected_file: &str,
    addr_label: &str,
    upgrade_type: ZksyncOSUpgradeType,
) {
    let (expected_len, observable_range) = match upgrade_type {
        ZksyncOSUpgradeType::UnsafeForceDeployment => (96usize, 64..96),
        ZksyncOSUpgradeType::SystemProxyUpgrade => (320usize, 160..192),
    };

    if bytecode_info.len() != expected_len {
        result.report_error(&format!(
            "ZKsyncOS force deployment at {addr_label} ({expected_file}): \
             deployedBytecodeInfo length {} expected {expected_len}",
            bytecode_info.len()
        ));
        return;
    }

    let observable = FixedBytes::<32>::from_slice(&bytecode_info[observable_range]);
    if evm_deployed_bytecode_hash_matches_file(verifiers, &observable, expected_file) {
        // ok — no noise on success to keep output readable
    } else {
        let actual_file = verifiers
            .bytecode_verifier
            .evm_deployed_bytecode_hash_to_file(&observable)
            .cloned()
            .unwrap_or_else(|| format!("unknown hash {observable}"));
        result.report_error(&format!(
            "ZKsyncOS force deployment at {addr_label}: expected file {expected_file}, \
             observable hash maps to {actual_file}"
        ));
    }
}

// Mirrors CoreOnGatewayHelper.getFullListOfFactoryDependencies(false, [L2V31Upgrade]).
const EXPECTED_V31_ERA_BYTECODES: &[&str] = &[
    "Bootloader",
    "system-contracts/DefaultAccount",
    "EvmEmulator",
    "system-contracts/EmptyContract",
    "Ecrecover",
    "SHA256",
    "Identity",
    "EcAdd",
    "EcMul",
    "EcPairing",
    "Modexp",
    "system-contracts/AccountCodeStorage",
    "system-contracts/NonceHolder",
    "system-contracts/KnownCodesStorage",
    "system-contracts/ImmutableSimulator",
    "system-contracts/ContractDeployer",
    "system-contracts/L1Messenger",
    "system-contracts/MsgValueSimulator",
    "l1-contracts/L2BaseTokenEra",
    "system-contracts/SystemContext",
    "system-contracts/BootloaderUtilities",
    "EventWriter",
    "system-contracts/Compressor",
    "Keccak256",
    "CodeOracle",
    "EvmGasManager",
    "system-contracts/EvmPredeploysManager",
    "system-contracts/EvmHashesStorage",
    "P256Verify",
    "system-contracts/PubdataChunkPublisher",
    "system-contracts/Create2Factory",
    "system-contracts/SloadContract",
    "l1-contracts/SystemContractProxyAdmin",
    "l1-contracts/L2Bridgehub",
    "l1-contracts/L2AssetRouter",
    "l1-contracts/L2NativeTokenVault",
    "l1-contracts/L2MessageRoot",
    "l1-contracts/L2WrappedBaseToken",
    "l1-contracts/L2MessageVerification",
    "l1-contracts/L2ChainAssetHandler",
    "l1-contracts/L2InteropRootStorage",
    "l1-contracts/BaseTokenHolder",
    "l1-contracts/L2AssetTracker",
    "l1-contracts/InteropCenter",
    "l1-contracts/InteropHandler",
    "l1-contracts/GWAssetTracker",
    "l1-contracts/TransparentUpgradeableProxy",
    "l1-contracts/BeaconProxy",
    "l1-contracts/L2SharedBridgeLegacy",
    "l1-contracts/BridgedStandardERC20",
    "l1-contracts/DiamondProxy",
    "l1-contracts/ProxyAdmin",
    "l1-contracts/L2V31Upgrade",
];

// Mirrors CoreOnGatewayHelper.getFullListOfFactoryDependencies(true, [L2V31Upgrade]).
const EXPECTED_V31_ZKSYNC_OS_BYTECODES: &[&str] = &[
    "l1-contracts/SystemContractProxy",
    "l1-contracts/SystemContractProxyAdmin",
    "l1-contracts/L2Bridgehub",
    "l1-contracts/L2AssetRouter",
    "l1-contracts/L2NativeTokenVaultZKOS",
    "l1-contracts/L2MessageRoot",
    "l1-contracts/L2WrappedBaseToken",
    "l1-contracts/L2MessageVerification",
    "l1-contracts/L2ChainAssetHandler",
    "l1-contracts/L2InteropRootStorage",
    "l1-contracts/BaseTokenHolder",
    "l1-contracts/L2AssetTracker",
    "l1-contracts/InteropCenter",
    "l1-contracts/InteropHandler",
    "l1-contracts/GWAssetTracker",
    "l1-contracts/UpgradeableBeaconDeployer",
    "l1-contracts/L2V31Upgrade",
    "l1-contracts/L2BaseTokenZKOS",
    "l1-contracts/L1MessengerZKOS",
    "l1-contracts/SystemContext",
];

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

    interface IL2V31Upgrade {
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

#[derive(Debug, Clone, Copy)]
enum FactoryDepHashKind {
    EraZkBytecode,
    ZksyncOsEvmBytecode,
}

impl ProposedUpgrade {
    pub async fn verify_v31_template(
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

        self.verify_static_fields(result, verifiers, expected_new_protocol_version, ctm_flavor);
        self.verify_l2_protocol_upgrade_tx(
            verifiers,
            result,
            expected_version,
            expected_fixed_force_deployments_data,
            bytecodes_supplier_addr,
        )
        .await?;

        let new_errors = (result.errors - initial_error_count) as usize;
        if new_errors == 0 {
            result.report_ok("DefaultUpgrade ProposedUpgrade matches v31 template");
        }
        Ok(new_errors)
    }

    fn verify_static_fields(
        &self,
        result: &mut VerificationResult,
        verifiers: &Verifiers,
        expected_new_protocol_version: U256,
        ctm_flavor: CtmFlavor,
    ) {
        match ctm_flavor {
            CtmFlavor::Era => {
                result.expect_zk_bytecode(verifiers, &self.bootloaderHash, BOOTLOADER_CONTRACT);
                result.expect_zk_bytecode(
                    verifiers,
                    &self.defaultAccountHash,
                    DEFAULT_ACCOUNT_CONTRACT,
                );
                result.expect_zk_bytecode(verifiers, &self.evmEmulatorHash, EVM_EMULATOR_CONTRACT);
            }
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
            result.report_error("ProposedUpgrade l1ContractsUpgradeCalldata must be empty for v31");
        }

        if !self.postUpgradeCalldata.is_empty() {
            result.report_error("ProposedUpgrade postUpgradeCalldata must be empty for v31");
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

    async fn verify_l2_protocol_upgrade_tx(
        &self,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
        expected_version: ProtocolVersion,
        expected_fixed_force_deployments_data: &str,
        bytecodes_supplier_addr: Option<Address>,
    ) -> anyhow::Result<()> {
        let tx = &self.l2ProtocolUpgradeTx;

        if tx.from != U256::from(L2_FORCE_DEPLOYER_ADDRESS) {
            result.report_error(&format!(
                "Invalid L2 upgrade tx sender: expected 0x{L2_FORCE_DEPLOYER_ADDRESS:x}, got {}",
                tx.from
            ));
        }
        if tx.to != U256::from(L2_COMPLEX_UPGRADER_ADDRESS) {
            result.report_error(&format!(
                "Invalid L2 upgrade tx target: expected 0x{L2_COMPLEX_UPGRADER_ADDRESS:x}, got {}",
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

        if let Ok(decoded) = IComplexUpgrader::forceDeployAndUpgradeCall::abi_decode(&tx.data) {
            if tx.txType != U256::from(ERA_SYSTEM_UPGRADE_TX_TYPE) {
                result.report_error(&format!(
                    "Era L2 upgrade tx must use txType {ERA_SYSTEM_UPGRADE_TX_TYPE}, got {}",
                    tx.txType
                ));
            }
            verify_factory_deps(
                verifiers,
                result,
                &tx.factoryDeps,
                EXPECTED_V31_ERA_BYTECODES,
                "Era",
                bytecodes_supplier_addr,
                FactoryDepHashKind::EraZkBytecode,
            )
            .await;
            verify_era_force_deploy_and_upgrade(
                verifiers,
                result,
                &decoded,
                expected_fixed_force_deployments_data,
            )
            .await?;
            result.report_ok("Decoded Era forceDeployAndUpgrade L2 upgrade tx");
            return Ok(());
        }

        if let Ok(decoded) =
            IComplexUpgrader::forceDeployAndUpgradeUniversalCall::abi_decode(&tx.data)
        {
            if tx.txType != U256::from(ZKSYNC_OS_SYSTEM_UPGRADE_TX_TYPE) {
                result.report_error(&format!(
                    "ZKsync OS L2 upgrade tx must use txType {ZKSYNC_OS_SYSTEM_UPGRADE_TX_TYPE}, got {}",
                    tx.txType
                ));
            }
            verify_factory_deps(
                verifiers,
                result,
                &tx.factoryDeps,
                EXPECTED_V31_ZKSYNC_OS_BYTECODES,
                "ZKsync OS",
                bytecodes_supplier_addr,
                FactoryDepHashKind::ZksyncOsEvmBytecode,
            )
            .await;
            verify_zksync_os_force_deploy_and_upgrade(
                verifiers,
                result,
                &decoded,
                expected_fixed_force_deployments_data,
            )
            .await?;
            result.report_ok("Decoded ZKsync OS forceDeployAndUpgradeUniversal L2 upgrade tx");
            return Ok(());
        }

        result.report_error(
            "L2 upgrade tx data is neither forceDeployAndUpgrade nor forceDeployAndUpgradeUniversal",
        );
        Ok(())
    }
}

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
            "{label} L2 upgrade tx factoryDeps match expected v31 dependency set"
        ));
    }

    // Re-add the legacy PUVT `BytecodesSupplier.publishingBlock(hash) != 0`
    // check for every factoryDep when an RPC + supplier address are
    // available (Phase 5 of puvt-what-to-do.md). This is intentionally a
    // post-calldata check: it requires reading on-chain state from a live
    // L1 RPC with the v31 prepare bundles already replayed.
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

async fn verify_era_force_deploy_and_upgrade(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    decoded: &IComplexUpgrader::forceDeployAndUpgradeCall,
    expected_fixed_force_deployments_data: &str,
) -> anyhow::Result<()> {
    let expected_delegate_to = address_from_short_u32(L2_VERSION_SPECIFIC_UPGRADER_ADDRESS);
    if decoded._delegateTo != expected_delegate_to {
        result.report_error(&format!(
            "Era forceDeployAndUpgrade delegate target mismatch: expected {}, got {}",
            expected_delegate_to, decoded._delegateTo
        ));
    } else {
        result.report_ok(&format!(
            "Era forceDeployAndUpgrade delegate target is L2_VERSION_SPECIFIC_UPGRADER_ADDR ({expected_delegate_to})"
        ));
    }

    verify_v31_era_force_deployments(verifiers, result, &decoded._forceDeployments).await?;

    verify_l2_v31_upgrade_inner_calldata(
        verifiers,
        result,
        &decoded._calldata,
        false,
        expected_fixed_force_deployments_data,
    )
    .await
}

fn verify_era_l2_v31_deployment(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    expected_delegate_to: Address,
    deployment: &IComplexUpgrader::ForceDeployment,
) {
    result.expect_zk_bytecode(verifiers, &deployment.bytecodeHash, L2_V31_UPGRADE_CONTRACT);
    if deployment.newAddress != expected_delegate_to {
        result.report_error(&format!(
            "Era L2V31Upgrade force deployment address must match delegate target: expected {}, got {}",
            expected_delegate_to, deployment.newAddress
        ));
    } else {
        result.report_ok(&format!(
            "Era L2V31Upgrade force deployment address is L2_VERSION_SPECIFIC_UPGRADER_ADDR ({expected_delegate_to})"
        ));
    }
    if deployment.callConstructor {
        result.report_error("Era L2V31Upgrade force deployment must not call a constructor");
    }
    if deployment.value != U256::ZERO {
        result.report_error(&format!(
            "Era L2V31Upgrade force deployment value must be zero, got {}",
            deployment.value
        ));
    }
    if !deployment.input.is_empty() {
        result.report_error("Era L2V31Upgrade force deployment constructor input must be empty");
    }
}

async fn verify_zksync_os_force_deploy_and_upgrade(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    decoded: &IComplexUpgrader::forceDeployAndUpgradeUniversalCall,
    expected_fixed_force_deployments_data: &str,
) -> anyhow::Result<()> {
    // Validate all expected force deployments (17 fixed entries; L2V31Upgrade delegate validated below).
    verify_v31_zksync_os_force_deployments(
        verifiers,
        result,
        &decoded._forceDeployments,
        decoded._delegateTo,
    );

    // Validate the L2V31Upgrade delegate-target entry (1 unsafe force deployment at a derived address).
    let mut matching_deployments = decoded
        ._forceDeployments
        .iter()
        .filter(|deployment| deployment.newAddress == decoded._delegateTo);
    match (matching_deployments.next(), matching_deployments.next()) {
        (Some(deployment), None) => {
            verify_zksync_os_l2_v31_deployment(verifiers, result, decoded._delegateTo, deployment);
        }
        (None, _) => result.report_error(&format!(
            "ZKsync OS forceDeployAndUpgradeUniversal does not deploy delegate target {}",
            decoded._delegateTo
        )),
        (Some(_), Some(_)) => result.report_error(&format!(
            "ZKsync OS forceDeployAndUpgradeUniversal contains multiple deployments for delegate target {}",
            decoded._delegateTo
        )),
    }

    verify_l2_v31_upgrade_inner_calldata(
        verifiers,
        result,
        &decoded._calldata,
        true,
        expected_fixed_force_deployments_data,
    )
    .await
}

fn verify_zksync_os_l2_v31_deployment(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    delegate_to: Address,
    deployment: &IComplexUpgrader::UniversalContractUpgradeInfo,
) {
    if deployment.upgradeType
        != IComplexUpgrader::ContractUpgradeType::ZKsyncOSUnsafeForceDeployment
    {
        result.report_error(&format!(
            "ZKsync OS L2V31Upgrade deployment must use ZKsyncOSUnsafeForceDeployment, got {:?}",
            deployment.upgradeType
        ));
    }

    let expected_delegate_to = generate_zksync_os_random_address(&deployment.deployedBytecodeInfo);
    if delegate_to != expected_delegate_to {
        result.report_error(&format!(
            "ZKsync OS delegate target mismatch: expected derived address {}, got {}",
            expected_delegate_to, delegate_to
        ));
    }

    match zksync_os_bytecode_info_hashes(&deployment.deployedBytecodeInfo) {
        Some((first_hash, observable_hash)) => {
            if evm_deployed_bytecode_hash_matches_file(
                verifiers,
                &observable_hash,
                L2_V31_UPGRADE_CONTRACT,
            ) {
                result.report_ok("ZKsync OS delegate deployment uses L2V31Upgrade bytecode info");
            } else {
                result.report_error(&format!(
                    "ZKsync OS delegate bytecode info does not map to {}: blake={}, observable={}",
                    L2_V31_UPGRADE_CONTRACT, first_hash, observable_hash
                ));
            }
        }
        None => result.report_error(&format!(
            "ZKsync OS L2V31Upgrade bytecode info must be 96 bytes, got {}",
            deployment.deployedBytecodeInfo.len()
        )),
    }
}

async fn verify_l2_v31_upgrade_inner_calldata(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    calldata: &[u8],
    expected_is_zksync_os: bool,
    expected_fixed_force_deployments_data: &str,
) -> anyhow::Result<()> {
    let decoded = IL2V31Upgrade::upgradeCall::abi_decode(calldata)
        .context("decoding IL2V31Upgrade.upgrade inner calldata")?;

    if decoded._isZKsyncOS != expected_is_zksync_os {
        result.report_error(&format!(
            "IL2V31Upgrade.upgrade _isZKsyncOS mismatch: expected {}, got {}",
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
                "IL2V31Upgrade.upgrade fixedForceDeploymentsData mismatch. Expected: 0x{}\nReceived: 0x{}",
                expected, actual
            ));
        } else {
            result.report_ok("IL2V31Upgrade.upgrade fixedForceDeploymentsData matches TOML");
        }
    }

    // Decode fixedForceDeploymentsData and verify each field independently so
    // the artifact hex is not merely trusted as a self-referential source of truth.
    result.print_info("-- fixedForceDeploymentsData field verification (inner calldata) --");
    match FixedForceDeploymentsData::abi_decode(&decoded._fixedForceDeploymentsData) {
        Ok(fixed_data) => fixed_data.verify(verifiers, result).await?,
        Err(err) => result.report_error(&format!(
            "Failed to decode IL2V31Upgrade.upgrade fixedForceDeploymentsData: {err}"
        )),
    }

    if !decoded._additionalForceDeploymentsData.is_empty() {
        result.report_error(
            "IL2V31Upgrade.upgrade additionalForceDeploymentsData template must be empty",
        );
    } else {
        result.report_ok("IL2V31Upgrade.upgrade additionalForceDeploymentsData template is empty");
    }

    Ok(())
}

fn fixed_bytes_from_u256(value: &U256) -> FixedBytes<32> {
    FixedBytes::<32>::from_slice(&value.to_be_bytes::<32>())
}

fn address_from_short_u32(value: u32) -> Address {
    let encoded = U256::from(value).to_be_bytes::<32>();
    Address::from_slice(&encoded[12..])
}

fn generate_zksync_os_random_address(bytecode_info: &[u8]) -> Address {
    let mut preimage = Vec::with_capacity(32 + bytecode_info.len());
    preimage.extend_from_slice(&[0u8; 32]);
    preimage.extend_from_slice(bytecode_info);
    let hash = keccak256(preimage);
    Address::from_slice(&hash[12..])
}

fn zksync_os_bytecode_info_hashes(
    bytecode_info: &[u8],
) -> Option<(FixedBytes<32>, FixedBytes<32>)> {
    if bytecode_info.len() != 96 {
        return None;
    }
    Some((
        FixedBytes::<32>::from_slice(&bytecode_info[0..32]),
        FixedBytes::<32>::from_slice(&bytecode_info[64..96]),
    ))
}

fn bytecode_hash_matches_file(
    verifiers: &Verifiers,
    bytecode_hash: &FixedBytes<32>,
    expected_file: &str,
) -> bool {
    verifiers
        .bytecode_verifier
        .zk_bytecode_hash_to_file(bytecode_hash)
        .is_some_and(|file| file == expected_file)
}

fn evm_deployed_bytecode_hash_matches_file(
    verifiers: &Verifiers,
    bytecode_hash: &FixedBytes<32>,
    expected_file: &str,
) -> bool {
    verifiers
        .bytecode_verifier
        .evm_deployed_bytecode_hash_to_file(bytecode_hash)
        .is_some_and(|file| file == expected_file)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn address_from_short_u32_preserves_system_contract_address() {
        let expected: Address = "0x0000000000000000000000000000000000010001"
            .parse()
            .unwrap();
        assert_eq!(
            address_from_short_u32(L2_VERSION_SPECIFIC_UPGRADER_ADDRESS),
            expected
        );
    }

    #[test]
    fn zksync_os_random_address_matches_helper_preimage_shape() {
        let expected: Address = "0xbcd8f33061f2577d6118395e7b44ea21c7ef62e0"
            .parse()
            .unwrap();
        assert_eq!(generate_zksync_os_random_address(&[1u8]), expected);
    }

    #[test]
    fn zksync_os_bytecode_info_hashes_requires_abi_tuple_size() {
        let mut bytecode_info = [0u8; 96];
        bytecode_info[31] = 1;
        bytecode_info[95] = 2;

        let (first_hash, observable_hash) = zksync_os_bytecode_info_hashes(&bytecode_info).unwrap();
        assert_eq!(first_hash[31], 1);
        assert_eq!(observable_hash[31], 2);
        assert!(zksync_os_bytecode_info_hashes(&bytecode_info[..95]).is_none());
    }
}
