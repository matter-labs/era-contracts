//! Era-VM `forceDeployAndUpgrade` payload verification.
//!
//! Owns the expected `ForceDeployment[]` list (44 entries: 31 EraVM system
//! contracts + 12 fixed-address core contracts + L2V33Upgrade), the per-entry
//! shape walker, the special `L2ChainAssetHandler` constructor-input decoder,
//! the Era factory-dep bytecode list, and the Era orchestrator wired from
//! `ProposedUpgrade::verify_l2_protocol_upgrade_tx`.

use alloy::{
    primitives::{Address, U256},
    sol_types::SolValue,
};
use std::collections::HashMap;

use crate::upgrade_verification::{
    constants::{
        literal_addr, CODE_ORACLE_SYSTEM_CONTRACT, ECADD_SYSTEM_CONTRACT, ECMUL_SYSTEM_CONTRACT,
        ECPAIRING_SYSTEM_CONTRACT, ECRECOVER_SYSTEM_CONTRACT, EVENT_WRITER_CONTRACT,
        EVM_GAS_MANAGER, EVM_PREDEPLOYS_MANAGER, IDENTITY_SYSTEM_CONTRACT,
        KECCAK256_SYSTEM_CONTRACT, L2_ACCOUNT_CODE_STORAGE_ADDR, L2_ASSET_ROUTER_ADDR,
        L2_ASSET_TRACKER_ADDR, L2_BASE_TOKEN_HOLDER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
        L2_BOOTLOADER_ADDRESS, L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_COMPRESSOR_ADDR,
        L2_CREATE2_FACTORY_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_INTEROP_CENTER_ADDR,
        L2_INTEROP_HANDLER_ADDR, L2_INTEROP_ROOT_STORAGE_ADDR,
        L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR, L2_MESSAGE_ROOT_ADDR,
        L2_MESSAGE_VERIFICATION_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_PUBDATA_CHUNK_PUBLISHER_ADDR,
        L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_V33_UPGRADE_CONTRACT,
        L2_VERSION_SPECIFIC_UPGRADER_ADDR, MODEXP_SYSTEM_CONTRACT, MSG_VALUE_SYSTEM_CONTRACT,
        SHA256_SYSTEM_CONTRACT, SLOAD_CONTRACT_ADDR,
    },
    verifiers::{VerificationResult, Verifiers},
};

use super::{verify_l2_v31_upgrade_inner_calldata, IComplexUpgrader};

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
/// then fixed-address core contracts (_fillFixedAddressCoreContracts), then L2V33Upgrade.
fn expected_v31_era_force_deployments() -> Vec<EraExpectedFd> {
    macro_rules! simple {
        ($file:expr, $addr:literal) => {
            EraExpectedFd {
                address: literal_addr($addr),
                file: $file,
                call_constructor: false,
                input_kind: EraFdInput::Empty,
            }
        };
        ($file:expr, $addr:expr) => {
            EraExpectedFd {
                address: $addr,
                file: $file,
                call_constructor: false,
                input_kind: EraFdInput::Empty,
            }
        };
    }
    vec![
        // ── EraVM system contracts (SYSTEM_CONTRACTS_COUNT = 31) ──
        // 0x0000, 0x0100, 0x8003, 0x8005, 0x800c, 0x8015 have no Solidity-side
        // named constant — they remain bare hex via the macro `:literal` arm.
        simple!("system-contracts/EmptyContract", 0x0000),
        simple!("Ecrecover", ECRECOVER_SYSTEM_CONTRACT),
        simple!("SHA256", SHA256_SYSTEM_CONTRACT),
        simple!("Identity", IDENTITY_SYSTEM_CONTRACT),
        simple!("EcAdd", ECADD_SYSTEM_CONTRACT),
        simple!("EcMul", ECMUL_SYSTEM_CONTRACT),
        simple!("EcPairing", ECPAIRING_SYSTEM_CONTRACT),
        simple!("Modexp", MODEXP_SYSTEM_CONTRACT),
        simple!("system-contracts/EmptyContract", L2_BOOTLOADER_ADDRESS), // bootloader slot
        simple!(
            "system-contracts/AccountCodeStorage",
            L2_ACCOUNT_CODE_STORAGE_ADDR
        ),
        simple!("system-contracts/NonceHolder", 0x8003),
        simple!(
            "system-contracts/KnownCodesStorage",
            L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR
        ),
        simple!("system-contracts/ImmutableSimulator", 0x8005),
        simple!(
            "system-contracts/ContractDeployer",
            L2_DEPLOYER_SYSTEM_CONTRACT_ADDR
        ),
        simple!(
            "system-contracts/L1Messenger",
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR
        ),
        simple!(
            "system-contracts/MsgValueSimulator",
            MSG_VALUE_SYSTEM_CONTRACT
        ),
        // L2BaseToken bytecode is L2BaseTokenEra
        simple!(
            "l1-contracts/L2BaseTokenEra",
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR
        ),
        simple!(
            "system-contracts/SystemContext",
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR
        ),
        simple!("system-contracts/BootloaderUtilities", 0x800c),
        simple!("EventWriter", EVENT_WRITER_CONTRACT),
        simple!("system-contracts/Compressor", L2_COMPRESSOR_ADDR),
        simple!("Keccak256", KECCAK256_SYSTEM_CONTRACT),
        simple!(
            "system-contracts/PubdataChunkPublisher",
            L2_PUBDATA_CHUNK_PUBLISHER_ADDR
        ),
        simple!("CodeOracle", CODE_ORACLE_SYSTEM_CONTRACT),
        simple!("EvmGasManager", EVM_GAS_MANAGER),
        simple!(
            "system-contracts/EvmPredeploysManager",
            EVM_PREDEPLOYS_MANAGER
        ),
        simple!("system-contracts/EvmHashesStorage", 0x8015),
        simple!("P256Verify", 0x0100),
        simple!("system-contracts/Create2Factory", L2_CREATE2_FACTORY_ADDR),
        simple!("system-contracts/SloadContract", SLOAD_CONTRACT_ADDR),
        simple!(
            "l1-contracts/SystemContractProxyAdmin",
            L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR
        ),
        // ── Fixed-address core contracts (FIXED_ADDRESS_CORE_CONTRACTS_COUNT = 12; L2WrappedBaseToken excluded) ──
        simple!("l1-contracts/L2Bridgehub", L2_BRIDGEHUB_ADDR),
        simple!("l1-contracts/L2AssetRouter", L2_ASSET_ROUTER_ADDR),
        simple!(
            "l1-contracts/L2NativeTokenVault",
            L2_NATIVE_TOKEN_VAULT_ADDR
        ),
        simple!("l1-contracts/L2MessageRoot", L2_MESSAGE_ROOT_ADDR),
        // L2WrappedBaseToken is intentionally NOT force-deployed by v31 (its impl is left as-is).
        simple!(
            "l1-contracts/L2MessageVerification",
            L2_MESSAGE_VERIFICATION_ADDR
        ),
        // L2ChainAssetHandler: callConstructor=true, special input
        EraExpectedFd {
            address: L2_CHAIN_ASSET_HANDLER_ADDR,
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
        // ── Additional: L2V33Upgrade (the delegate target for this upgrade) ──
        simple!(L2_V33_UPGRADE_CONTRACT, L2_VERSION_SPECIFIC_UPGRADER_ADDR),
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

    let expected_aliased_governance = verifiers
        .address_verifier
        .get_by_name("aliased_protocol_upgrade_handler_proxy")
        .expect("aliased_protocol_upgrade_handler_proxy must be registered by Verifiers::new_v31");
    if aliased_owner == expected_aliased_governance {
        result.report_ok("L2ChainAssetHandler input aliasedOwner matches aliased governance");
    } else {
        result.report_error(&format!(
            "L2ChainAssetHandler input aliasedOwner: expected {expected_aliased_governance}, got {aliased_owner}"
        ));
    }

    if l2_bridgehub != L2_BRIDGEHUB_ADDR {
        result.report_error(&format!(
            "L2ChainAssetHandler input l2Bridgehub: expected {L2_BRIDGEHUB_ADDR}, got {l2_bridgehub}"
        ));
    }
    if l2_asset_router != L2_ASSET_ROUTER_ADDR {
        result.report_error(&format!(
            "L2ChainAssetHandler input l2AssetRouter: expected {L2_ASSET_ROUTER_ADDR}, got {l2_asset_router}"
        ));
    }
    if l2_message_root != L2_MESSAGE_ROOT_ADDR {
        result.report_error(&format!(
            "L2ChainAssetHandler input l2MessageRoot: expected {L2_MESSAGE_ROOT_ADDR}, got {l2_message_root}"
        ));
    }
}

/// Era L2 factory-dep bytecode set. Mirrors
/// `CoreOnGatewayHelper.getFullListOfFactoryDependencies(false, [L2V33Upgrade])`.
pub(super) const EXPECTED_V31_ERA_BYTECODES: &[&str] = &[
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
    "l1-contracts/L2MessageVerification",
    "l1-contracts/L2ChainAssetHandler",
    "l1-contracts/L2InteropRootStorage",
    "l1-contracts/BaseTokenHolder",
    "l1-contracts/L2AssetTracker",
    "l1-contracts/InteropCenter",
    "l1-contracts/InteropHandler",
    "l1-contracts/TransparentUpgradeableProxy",
    "l1-contracts/BeaconProxy",
    "l1-contracts/L2SharedBridgeLegacy",
    "l1-contracts/BridgedStandardERC20",
    "l1-contracts/DiamondProxy",
    "l1-contracts/ProxyAdmin",
    "l1-contracts/L2V33Upgrade",
];

/// Era orchestrator: validates the `_delegateTo`, walks the `ForceDeployment[]`,
/// and decodes the inner `IL2V33Upgrade.upgrade` calldata.
pub(super) async fn verify_era_force_deploy_and_upgrade(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    decoded: &IComplexUpgrader::forceDeployAndUpgradeCall,
    expected_fixed_force_deployments_data: &str,
) -> anyhow::Result<()> {
    let expected_delegate_to = L2_VERSION_SPECIFIC_UPGRADER_ADDR;
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
