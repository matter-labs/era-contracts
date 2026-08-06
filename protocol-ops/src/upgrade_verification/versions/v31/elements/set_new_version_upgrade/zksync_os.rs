//! ZKsync OS `forceDeployAndUpgradeUniversal` payload verification.
//!
//! Owns the expected `UniversalContractUpgradeInfo[]` list (16 fixed-address
//! entries, all proxy-upgrade shapes; the only unsafe force deployment is the
//! L2V32Upgrade delegate target, validated separately), the
//! deployed-bytecode-info decoder (96-byte triple or 320-byte impl/proxy
//! pair), the keccak-derived L2V32Upgrade delegate-address check, the ZKsync
//! OS factory-dep bytecode list, and the ZKsync OS orchestrator wired from
//! `ProposedUpgrade::verify_l2_protocol_upgrade_tx`.

use alloy::primitives::{keccak256, Address, FixedBytes};
use std::collections::HashMap;

use crate::upgrade_verification::{
    constants::{
        L2_ASSET_ROUTER_ADDR, L2_ATOMIC_FLOW_MANAGER_ADDR, L2_BASE_TOKEN_HOLDER_ADDR,
        L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR,
        L2_INTEROP_ATTRIBUTE_PARSER_ADDR, L2_INTEROP_CENTER_ADDR, L2_INTEROP_COMMITMENT_TREE_ADDR,
        L2_INTEROP_HANDLER_ADDR, L2_INTEROP_ROOT_STORAGE_ADDR, L2_MESSAGE_ROOT_ADDR,
        L2_MESSAGE_VERIFICATION_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR,
        L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
        L2_V32_UPGRADE_CONTRACT,
    },
    verifiers::{VerificationResult, Verifiers},
};

use super::{verify_l2_v31_upgrade_inner_calldata, IComplexUpgrader};

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
/// `ComplexUpgrader.forceDeployAndUpgradeUniversal` — excludes the L2V32Upgrade delegate-target
/// entry, which is validated separately by `verify_zksync_os_l2_v31_deployment`.
fn expected_v31_zksync_os_force_deployments() -> Vec<ZksyncOSExpectedFd> {
    macro_rules! proxy {
        ($file:expr, $addr:expr) => {
            ZksyncOSExpectedFd {
                address: $addr,
                file: $file,
                upgrade_type: ZksyncOSUpgradeType::SystemProxyUpgrade,
            }
        };
    }
    // NOTE: every entry below is a SystemProxyUpgrade. v31 no longer performs any unsafe
    // ZKsyncOS force deployment except the L2V32Upgrade delegate target (validated separately);
    // verify_v31_zksync_os_force_deployments enforces that no other unsafe FD is present.
    vec![
        // ── Fixed-address core contracts (getFixedAddressCoreContracts, 11 entries; L2WrappedBaseToken excluded) ──
        proxy!("l1-contracts/L2Bridgehub", L2_BRIDGEHUB_ADDR),
        proxy!("l1-contracts/L2AssetRouter", L2_ASSET_ROUTER_ADDR),
        proxy!(
            "l1-contracts/L2NativeTokenVaultZKOS",
            L2_NATIVE_TOKEN_VAULT_ADDR
        ),
        proxy!("l1-contracts/L2MessageRoot", L2_MESSAGE_ROOT_ADDR),
        // L2WrappedBaseToken is intentionally NOT force-deployed by v31 (its impl is left as-is).
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
        proxy!("l1-contracts/InteropCenter", L2_INTEROP_CENTER_ADDR),
        proxy!("l1-contracts/L2InteropHandler", L2_INTEROP_HANDLER_ADDR),
        proxy!(
            "l1-contracts/InteropAttributeParser",
            L2_INTEROP_ATTRIBUTE_PARSER_ADDR
        ),
        // ── ZKsync-OS-only atomic-interop built-ins (getZKsyncOSOnlyContracts, 2 entries) ──
        proxy!(
            "l1-contracts/L2InteropCommitmentTree",
            L2_INTEROP_COMMITMENT_TREE_ADDR
        ),
        proxy!(
            "l1-contracts/AtomicFlowManager",
            L2_ATOMIC_FLOW_MANAGER_ADDR
        ),
        // ── ZKsync-OS system contracts (getZKsyncOSExtraSystemContracts, 3 entries) ──
        proxy!(
            "l1-contracts/L2BaseTokenZKOS",
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR
        ),
        proxy!(
            "l1-contracts/L1MessengerZKOS",
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR
        ),
        proxy!(
            "l1-contracts/SystemContext",
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR
        ),
        // ── ProxyAdmin (0x1000c) is a direct-deployed contract present from genesis; v31 no longer
        //    force-deploys it (it would require an unsafe overwrite), so it is not in this list. ──
    ]
}

/// Validate all entries of `UniversalContractUpgradeInfo[]` except the L2V32Upgrade delegate-target
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
        // Skip the L2V32Upgrade delegate-target; already validated elsewhere. It is the ONLY
        // ZKsyncOS force deployment allowed to be unsafe (it's the delegatecall implementation).
        if deployment.newAddress == delegate_to {
            continue;
        }

        // Guard: no other entry may be an unsafe force deployment. v31 deliberately uses only
        // SystemProxyUpgrade for the fixed-address contracts; an unsafe FD here would overwrite
        // bytecode in place (e.g. the old L2WrappedBaseToken / SystemContractProxyAdmin entries),
        // which we have removed. Catch any regression that reintroduces one.
        if deployment.upgradeType
            == IComplexUpgrader::ContractUpgradeType::ZKsyncOSUnsafeForceDeployment
        {
            result.report_error(&format!(
                "Unsafe ZKsyncOS force deployment at {} is not allowed (only the L2V32Upgrade \
                 delegate target may use ZKsyncOSUnsafeForceDeployment)",
                deployment.newAddress
            ));
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
            "All ZKsyncOS force deployments match the expected v31 list (excluding L2V32Upgrade delegate target)",
        );
    }
}

/// Verify the `deployedBytecodeInfo` of a ZKsyncOS force deployment entry maps to the expected file.
///
/// `deployedBytecodeInfo` is `(bytes32 blakeHash, uint32 length, bytes32 observableKeccak)`
/// per `IComplexUpgrader.sol:27`. ZKsync OS L2's `setBytecodeDetailsEVM` consumes all
/// three — for fixed-address entries the `newAddress` is fixed and can't bind the tuple
/// via address derivation (unlike the L2V32Upgrade delegate target), so PUVT must
/// independently cross-check each component against `AllContractsHashes.json`.
///
/// - `ZKsyncOSUnsafeForceDeployment`: 96-byte triple, fields at `[0..32]` / `[32..64]` / `[64..96]`.
/// - `ZKsyncOSSystemProxyUpgrade`: `abi.encode(implInfo_bytes, proxyInfo_bytes)` = 320 bytes; the
///   impl triple lives at `[96..192]` after the two offsets + impl length-prefix.
fn verify_zksync_os_deployed_bytecode_info(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    bytecode_info: &[u8],
    expected_file: &str,
    addr_label: &str,
    upgrade_type: ZksyncOSUpgradeType,
) {
    let expected_len = match upgrade_type {
        ZksyncOSUpgradeType::UnsafeForceDeployment => 96usize,
        ZksyncOSUpgradeType::SystemProxyUpgrade => 320usize,
    };

    if bytecode_info.len() != expected_len {
        result.report_error(&format!(
            "ZKsyncOS force deployment at {addr_label} ({expected_file}): \
             deployedBytecodeInfo length {} expected {expected_len}",
            bytecode_info.len()
        ));
        return;
    }

    match upgrade_type {
        ZksyncOSUpgradeType::UnsafeForceDeployment => verify_zksync_os_bytecode_info_triplet(
            verifiers,
            result,
            bytecode_info,
            expected_file,
            addr_label,
            0,
            32,
            64,
        ),
        ZksyncOSUpgradeType::SystemProxyUpgrade => {
            verify_zksync_os_bytecode_info_triplet(
                verifiers,
                result,
                bytecode_info,
                expected_file,
                &format!("{addr_label} [implementation]"),
                96,
                128,
                160,
            );
            verify_zksync_os_bytecode_info_triplet(
                verifiers,
                result,
                bytecode_info,
                "l1-contracts/SystemContractProxy",
                &format!("{addr_label} [proxy]"),
                224,
                256,
                288,
            );
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn verify_zksync_os_bytecode_info_triplet(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    bytecode_info: &[u8],
    expected_file: &str,
    addr_label: &str,
    blake_start: usize,
    length_word_start: usize,
    observable_start: usize,
) {
    let observable =
        FixedBytes::<32>::from_slice(&bytecode_info[observable_start..observable_start + 32]);
    if !evm_deployed_bytecode_hash_matches_file(verifiers, &observable, expected_file) {
        let actual_file = verifiers
            .bytecode_verifier
            .evm_deployed_bytecode_hash_to_file(&observable)
            .cloned()
            .unwrap_or_else(|| format!("unknown hash {observable}"));
        result.report_error(&format!(
            "ZKsyncOS force deployment at {addr_label}: expected file {expected_file}, \
             observable hash maps to {actual_file}"
        ));
        // Continue: blake + length below may still surface useful errors.
    }

    let Some((expected_blake, expected_length)) = verifiers
        .bytecode_verifier
        .evm_deployed_blake_and_length(expected_file)
    else {
        result.report_warn(&format!(
            "ZKsyncOS force deployment at {addr_label} ({expected_file}): \
             AllContractsHashes.json lacks blake/length for this file; \
             only observableKeccak is cross-checked"
        ));
        return;
    };

    let actual_blake = FixedBytes::<32>::from_slice(&bytecode_info[blake_start..blake_start + 32]);
    if actual_blake != expected_blake {
        result.report_error(&format!(
            "ZKsyncOS force deployment at {addr_label} ({expected_file}): \
             deployedBytecodeInfo.blakeHash mismatch: expected {expected_blake}, got {actual_blake}"
        ));
    }

    // `uint32 length` is padded to a full 32-byte word; the value lives in the
    // last 4 big-endian bytes.
    let length_word = &bytecode_info[length_word_start..length_word_start + 32];
    let actual_length = u32::from_be_bytes(length_word[28..32].try_into().unwrap());
    if actual_length != expected_length {
        result.report_error(&format!(
            "ZKsyncOS force deployment at {addr_label} ({expected_file}): \
             deployedBytecodeInfo.length mismatch: expected {expected_length}, got {actual_length}"
        ));
    }
}

/// ZKsync OS L2 factory-dep bytecode set. Mirrors
/// `CoreOnGatewayHelper.getFullListOfFactoryDependencies(true, [L2V32Upgrade])`.
pub(super) const EXPECTED_V31_ZKSYNC_OS_BYTECODES: &[&str] = &[
    "l1-contracts/SystemContractProxy",
    "l1-contracts/SystemContractProxyAdmin",
    "l1-contracts/L2Bridgehub",
    "l1-contracts/L2AssetRouter",
    "l1-contracts/L2NativeTokenVaultZKOS",
    "l1-contracts/L2MessageRoot",
    "l1-contracts/L2MessageVerification",
    "l1-contracts/L2ChainAssetHandler",
    "l1-contracts/L2InteropRootStorage",
    "l1-contracts/BaseTokenHolder",
    "l1-contracts/InteropCenter",
    "l1-contracts/L2InteropHandler",
    "l1-contracts/InteropAttributeParser",
    "l1-contracts/L2InteropCommitmentTree",
    "l1-contracts/AtomicFlowManager",
    "l1-contracts/UpgradeableBeaconDeployer",
    "l1-contracts/L2V32Upgrade",
    "l1-contracts/L2BaseTokenZKOS",
    "l1-contracts/L1MessengerZKOS",
    "l1-contracts/SystemContext",
];

/// ZKsync OS orchestrator: walks the `UniversalContractUpgradeInfo[]`, validates the
/// L2V32Upgrade delegate-target entry (derived address + bytecode info), then decodes
/// the inner `IL2V32Upgrade.upgrade` calldata.
pub(super) async fn verify_zksync_os_force_deploy_and_upgrade(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    decoded: &IComplexUpgrader::forceDeployAndUpgradeUniversalCall,
    expected_fixed_force_deployments_data: &str,
) -> anyhow::Result<()> {
    // Validate all expected force deployments (16 fixed entries; L2V32Upgrade delegate validated below).
    verify_v31_zksync_os_force_deployments(
        verifiers,
        result,
        &decoded._forceDeployments,
        decoded._delegateTo,
    );

    // Validate the L2V32Upgrade delegate-target entry (1 unsafe force deployment at a derived address).
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
            "ZKsync OS L2V32Upgrade deployment must use ZKsyncOSUnsafeForceDeployment, got {:?}",
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
                L2_V32_UPGRADE_CONTRACT,
            ) {
                result.report_ok("ZKsync OS delegate deployment uses L2V32Upgrade bytecode info");
            } else {
                result.report_error(&format!(
                    "ZKsync OS delegate bytecode info does not map to {}: blake={}, observable={}",
                    L2_V32_UPGRADE_CONTRACT, first_hash, observable_hash
                ));
            }
        }
        None => result.report_error(&format!(
            "ZKsync OS L2V32Upgrade bytecode info must be 96 bytes, got {}",
            deployment.deployedBytecodeInfo.len()
        )),
    }
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

#[cfg(test)]
mod tests {
    use super::*;

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
