//! ZKsync OS `forceDeployAndUpgradeUniversal` payload verification.
//!
//! Owns the expected `UniversalContractUpgradeInfo[]` list (18 fixed-address
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
        L2_ASSET_ROUTER_ADDR, L2_ASSET_TRACKER_ADDR, L2_ATOMIC_FLOW_MANAGER_ADDR,
        L2_BASE_TOKEN_HOLDER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BRIDGEHUB_ADDR,
        L2_CHAIN_ASSET_HANDLER_ADDR, L2_INTEROP_ATTRIBUTE_PARSER_ADDR, L2_INTEROP_CENTER_ADDR,
        L2_INTEROP_COMMITMENT_TREE_ADDR, L2_INTEROP_HANDLER_ADDR, L2_INTEROP_ROOT_STORAGE_ADDR,
        L2_MESSAGE_ROOT_ADDR, L2_MESSAGE_VERIFICATION_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR,
        L2_REMOVED_GW_ASSET_TRACKER_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR,
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_V32_UPGRADE_CONTRACT,
    },
    verifiers::{VerificationResult, Verifiers},
};

use super::{verify_l2_upgrade_inner_calldata, IComplexUpgrader};

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

/// Expected v33 ZKsyncOS `UniversalContractUpgradeInfo[]` passed to
/// `ComplexUpgrader.forceDeployAndUpgradeUniversal` — excludes the L2V32Upgrade delegate-target
/// entry, which is validated separately by `verify_zksync_os_l2_v33_deployment`.
fn expected_v33_zksync_os_force_deployments() -> Vec<ZksyncOSExpectedFd> {
    macro_rules! proxy {
        ($file:expr, $addr:expr) => {
            ZksyncOSExpectedFd {
                address: $addr,
                file: $file,
                upgrade_type: ZksyncOSUpgradeType::SystemProxyUpgrade,
            }
        };
    }
    // NOTE: every entry below is a SystemProxyUpgrade. v33 no longer performs any unsafe
    // ZKsyncOS force deployment except the L2V32Upgrade delegate target (validated separately);
    // verify_v33_zksync_os_force_deployments enforces that no other unsafe FD is present.
    vec![
        // ── Fixed-address core contracts (getFixedAddressCoreContracts, 12 entries; L2WrappedBaseToken excluded) ──
        proxy!("l1-contracts/L2Bridgehub", L2_BRIDGEHUB_ADDR),
        proxy!("l1-contracts/L2AssetRouter", L2_ASSET_ROUTER_ADDR),
        proxy!(
            "l1-contracts/L2NativeTokenVaultZKOS",
            L2_NATIVE_TOKEN_VAULT_ADDR
        ),
        proxy!("l1-contracts/L2MessageRoot", L2_MESSAGE_ROOT_ADDR),
        // L2WrappedBaseToken is intentionally NOT force-deployed by v33 (its impl is left as-is).
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
        // ── Removed-tracker neutralizations (getRemovedTrackerNeutralizations, 1 entry):
        //    the v33 GWAssetTracker's proxy gets its implementation swapped for EmptyContract. ──
        proxy!(
            "l1-contracts/EmptyContract",
            L2_REMOVED_GW_ASSET_TRACKER_ADDR
        ),
        // ── ProxyAdmin (0x1000c) is a direct-deployed contract present from genesis; v33 no longer
        //    force-deploys it (it would require an unsafe overwrite), so it is not in this list. ──
    ]
}

/// Validate all entries of `UniversalContractUpgradeInfo[]` except the L2V32Upgrade delegate-target
/// (which is already validated by `verify_zksync_os_l2_v33_deployment`).
fn verify_v33_zksync_os_force_deployments(
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    deployments: &[IComplexUpgrader::UniversalContractUpgradeInfo],
    delegate_to: Address,
) {
    let expected = expected_v33_zksync_os_force_deployments();
    let mut expected_map: HashMap<Address, ZksyncOSExpectedFd> =
        expected.into_iter().map(|e| (e.address, e)).collect();

    for deployment in deployments {
        // Skip the L2V32Upgrade delegate-target; already validated elsewhere. It is the ONLY
        // ZKsyncOS force deployment allowed to be unsafe (it's the delegatecall implementation).
        if deployment.newAddress == delegate_to {
            continue;
        }

        // Guard: no other entry may be an unsafe force deployment. v33 deliberately uses only
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
            "All ZKsyncOS force deployments match the expected v33 list (excluding L2V32Upgrade delegate target)",
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
            SIMPLE_INFO_BLAKE_START,
            SIMPLE_INFO_LENGTH_START,
            SIMPLE_INFO_OBSERVABLE_START,
        ),
        ZksyncOSUpgradeType::SystemProxyUpgrade => {
            // Reading the two triplets at fixed offsets says nothing about the
            // envelope that carries them. A non-canonical header — a shifted
            // offset, a wrong inner length — leaves the payload exactly where
            // this code looks, so it would verify here and then be rejected by
            // Solidity's `abi.decode` during the L2 upgrade. Check the header
            // before trusting the offsets.
            if !verify_zksync_os_proxy_info_envelope(
                result,
                bytecode_info,
                expected_file,
                addr_label,
            ) {
                return;
            }
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

/// Canonical ABI header of a `ZKsyncOSSystemProxyUpgrade` descriptor,
/// `abi.encode(bytes implInfo, bytes proxyInfo)` where each `bytes` is one
/// 96-byte triplet. Solidity emits exactly these four words and rejects
/// anything else on decode, so they are fixed expectations rather than values
/// to be read and followed.
const PROXY_INFO_OFFSET_IMPL: usize = 64;
const PROXY_INFO_OFFSET_PROXY: usize = 192;
const PROXY_INFO_INNER_LEN: usize = 96;

/// Validates the envelope of a 320-byte proxy descriptor. Returns false when
/// the header is not canonical, in which case the payload offsets cannot be
/// trusted and the caller must not read them.
fn verify_zksync_os_proxy_info_envelope(
    result: &mut VerificationResult,
    bytecode_info: &[u8],
    expected_file: &str,
    addr_label: &str,
) -> bool {
    let word = |start: usize| -> Option<usize> {
        let w = &bytecode_info[start..start + 32];
        // A canonical offset/length fits in the low 8 bytes; anything in the
        // upper 24 is either an overflow attempt or garbage.
        if w[..24].iter().any(|b| *b != 0) {
            return None;
        }
        Some(u64::from_be_bytes(w[24..32].try_into().unwrap()) as usize)
    };

    let mut ok = true;
    for (start, expected, what) in [
        (0usize, PROXY_INFO_OFFSET_IMPL, "implementation offset"),
        (32, PROXY_INFO_OFFSET_PROXY, "proxy offset"),
        (64, PROXY_INFO_INNER_LEN, "implementation length"),
        (192, PROXY_INFO_INNER_LEN, "proxy length"),
    ] {
        match word(start) {
            Some(actual) if actual == expected => {}
            Some(actual) => {
                result.report_error(&format!(
                    "ZKsyncOS force deployment at {addr_label} ({expected_file}): \
                     deployedBytecodeInfo {what} is {actual}, expected {expected}; \
                     the descriptor is not canonical ABI and would fail L2-side decoding"
                ));
                ok = false;
            }
            None => {
                result.report_error(&format!(
                    "ZKsyncOS force deployment at {addr_label} ({expected_file}): \
                     deployedBytecodeInfo {what} has dirty high-order bytes"
                ));
                ok = false;
            }
        }
    }
    ok
}

/// A simple (non-proxy) ZKsync OS `deployedBytecodeInfo` is the 96-byte
/// triplet `abi.encode(blakeHash, uint32 length, observableKeccak)`.
pub(super) const ZKSYNC_OS_SIMPLE_BYTECODE_INFO_LEN: usize = 96;
const SIMPLE_INFO_BLAKE_START: usize = 0;
const SIMPLE_INFO_LENGTH_START: usize = 32;
const SIMPLE_INFO_OBSERVABLE_START: usize = 64;

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
    let errors_before = result.errors;
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
    // last 4 big-endian bytes and the other 28 must be zero. Reading only the
    // low 4 would accept a word whose high bytes carry anything at all.
    let length_word = &bytecode_info[length_word_start..length_word_start + 32];
    if length_word[..28].iter().any(|b| *b != 0) {
        result.report_error(&format!(
            "ZKsyncOS force deployment at {addr_label} ({expected_file}): \
             deployedBytecodeInfo.length is not a canonically padded uint32"
        ));
    }
    let actual_length = u32::from_be_bytes(length_word[28..32].try_into().unwrap());
    if actual_length != expected_length {
        result.report_error(&format!(
            "ZKsyncOS force deployment at {addr_label} ({expected_file}): \
             deployedBytecodeInfo.length mismatch: expected {expected_length}, got {actual_length}"
        ));
    }

    if result.errors == errors_before {
        result.report_ok(&format!(
            "{addr_label}: deployedBytecodeInfo blake+length+observableKeccak all match {expected_file}"
        ));
    }
}

/// ZKsync OS L2 factory-dep bytecode set. Mirrors
/// `CoreOnGatewayHelper.getFullListOfFactoryDependencies(true, [L2V32Upgrade])`.
pub(super) const EXPECTED_V33_ZKSYNC_OS_BYTECODES: &[&str] = &[
    "l1-contracts/SystemContractProxy",
    "l1-contracts/SystemContractProxyAdmin",
    "l1-contracts/EmptyContract",
    "l1-contracts/L2Bridgehub",
    "l1-contracts/L2AssetRouter",
    "l1-contracts/L2NativeTokenVaultZKOS",
    "l1-contracts/L2MessageRoot",
    "l1-contracts/L2MessageVerification",
    "l1-contracts/L2ChainAssetHandler",
    "l1-contracts/L2InteropRootStorage",
    "l1-contracts/BaseTokenHolder",
    "l1-contracts/L2AssetTracker",
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
    // Validate all expected force deployments (18 fixed entries; L2V32Upgrade delegate validated below).
    verify_v33_zksync_os_force_deployments(
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
            verify_zksync_os_l2_v33_deployment(verifiers, result, decoded._delegateTo, deployment);
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

    verify_l2_upgrade_inner_calldata(
        verifiers,
        result,
        &decoded._calldata,
        true,
        expected_fixed_force_deployments_data,
    )
    .await
}

fn verify_zksync_os_l2_v33_deployment(
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

    // The delegate's address is *derived* from this descriptor, so a matching
    // address proves only that the descriptor hashes to the address — not that
    // the descriptor describes L2V32Upgrade. All three fields are consumed by
    // the L2 deployer (`setBytecodeDetailsEVM`), so all three are checked:
    // altering blake or length and recomputing the address must not pass.
    if deployment.deployedBytecodeInfo.len() == ZKSYNC_OS_SIMPLE_BYTECODE_INFO_LEN {
        verify_zksync_os_bytecode_info_triplet(
            verifiers,
            result,
            &deployment.deployedBytecodeInfo,
            L2_V32_UPGRADE_CONTRACT,
            "L2V32Upgrade delegate target",
            SIMPLE_INFO_BLAKE_START,
            SIMPLE_INFO_LENGTH_START,
            SIMPLE_INFO_OBSERVABLE_START,
        );
    } else {
        result.report_error(&format!(
            "ZKsync OS L2V32Upgrade bytecode info must be {} bytes, got {}",
            ZKSYNC_OS_SIMPLE_BYTECODE_INFO_LEN,
            deployment.deployedBytecodeInfo.len()
        ));
    }
}

fn generate_zksync_os_random_address(bytecode_info: &[u8]) -> Address {
    let mut preimage = Vec::with_capacity(32 + bytecode_info.len());
    preimage.extend_from_slice(&[0u8; 32]);
    preimage.extend_from_slice(bytecode_info);
    let hash = keccak256(preimage);
    Address::from_slice(&hash[12..])
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

    fn canonical_proxy_envelope() -> [u8; 320] {
        let mut info = [0u8; 320];
        info[31] = 0x40; // offset of implInfo
        info[63] = 0xc0; // offset of proxyInfo
        info[95] = 0x60; // len(implInfo)  = 96
        info[223] = 0x60; // len(proxyInfo) = 96
        info
    }

    #[test]
    fn proxy_info_envelope_accepts_canonical_header() {
        let mut result = VerificationResult::default();
        assert!(verify_zksync_os_proxy_info_envelope(
            &mut result,
            &canonical_proxy_envelope(),
            "l1-contracts/L2Bridgehub",
            "0xdead",
        ));
        assert_eq!(result.errors, 0);
    }

    /// The mutation from the PR review: shifting the first offset by one leaves
    /// both triplets exactly where the fixed-offset reads look for them, so
    /// only an envelope check can reject it. Solidity's decoder does.
    #[test]
    fn proxy_info_envelope_rejects_offset_shifted_by_one() {
        let mut info = canonical_proxy_envelope();
        info[31] = 0x41;

        let mut result = VerificationResult::default();
        assert!(!verify_zksync_os_proxy_info_envelope(
            &mut result,
            &info,
            "l1-contracts/L2Bridgehub",
            "0xdead",
        ));
        assert_eq!(result.errors, 1);
    }

    #[test]
    fn proxy_info_envelope_rejects_wrong_inner_length() {
        let mut info = canonical_proxy_envelope();
        info[95] = 0x61;

        let mut result = VerificationResult::default();
        assert!(!verify_zksync_os_proxy_info_envelope(
            &mut result,
            &info,
            "l1-contracts/L2Bridgehub",
            "0xdead",
        ));
        assert_eq!(result.errors, 1);
    }

    #[test]
    fn proxy_info_envelope_rejects_dirty_high_order_bytes() {
        let mut info = canonical_proxy_envelope();
        info[0] = 1;

        let mut result = VerificationResult::default();
        assert!(!verify_zksync_os_proxy_info_envelope(
            &mut result,
            &info,
            "l1-contracts/L2Bridgehub",
            "0xdead",
        ));
        assert_eq!(result.errors, 1);
    }

    /// The simple-triplet field offsets the delegate check relies on.
    #[test]
    fn simple_bytecode_info_layout_is_blake_length_observable() {
        assert_eq!(SIMPLE_INFO_BLAKE_START, 0);
        assert_eq!(SIMPLE_INFO_LENGTH_START, 32);
        assert_eq!(SIMPLE_INFO_OBSERVABLE_START, 64);
        assert_eq!(
            SIMPLE_INFO_OBSERVABLE_START + 32,
            ZKSYNC_OS_SIMPLE_BYTECODE_INFO_LEN
        );
    }
}
