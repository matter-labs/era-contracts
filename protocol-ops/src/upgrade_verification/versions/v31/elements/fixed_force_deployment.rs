use alloy::primitives::{Address, FixedBytes, U256};
use alloy::sol;

use crate::upgrade_verification::verifiers::{VerificationResult, Verifiers};

use super::super::utils::apply_l2_to_l1_alias;
use super::super::MAX_NUMBER_OF_ZK_CHAINS;

sol! {
    #[sol(rpc)]
    interface BridgehubBase {
        function chainRegistrationSender() external view returns (address);
    }
}

sol! {
    #[derive(Debug)]
    struct FixedForceDeploymentsData {
        uint256 l1ChainId;
        uint256 eraGatewayChainId;
        uint256 eraChainId;
        address l1AssetRouter;
        bytes32 l2TokenProxyBytecodeHash;
        address aliasedL1Governance;
        uint256 maxNumberOfZKChains;
        bytes bridgehubBytecodeInfo;
        bytes l2AssetRouterBytecodeInfo;
        bytes l2NtvBytecodeInfo;
        bytes messageRootBytecodeInfo;
        bytes chainAssetHandlerBytecodeInfo;
        bytes interopCenterBytecodeInfo;
        bytes interopHandlerBytecodeInfo;
        bytes assetTrackerBytecodeInfo;
        bytes beaconDeployerInfo;
        bytes baseTokenHolderBytecodeInfo;
        address l2SharedBridgeLegacyImpl;
        address l2BridgedStandardERC20Impl;
        address aliasedChainRegistrationSender;
        // The forced beacon address. MUST be equal to 0 in production.
        address dangerousTestOnlyForcedBeacon;
        bytes32 zkTokenAssetId;
    }
}

// Era bytecodeInfo       = abi.encode(bytes32 zkHash)             = 32 bytes
// ZKsyncOS simple        = 96-byte triplet (blake|pad|keccak)     = 96 bytes  (unused here)
// ZKsyncOS proxy upgrade = abi.encode(implInfo_96, proxyInfo_96)  = 320 bytes
//
// For ZKsyncOS proxy (320 bytes), the impl observable hash lives at implInfo[64..96],
// which is at raw_bytes[96 + 64 .. 96 + 96] = bytes[160..192] inside the 320-byte blob
// (after the 64-byte ABI head + 32-byte length prefix).
fn expect_bytecode_info(
    result: &mut VerificationResult,
    verifiers: &Verifiers,
    bytecode_info: &[u8],
    era_expected: &str,
    zksync_os_expected: &str,
) {
    match bytecode_info.len() {
        32 => {
            let hash = FixedBytes::<32>::from_slice(bytecode_info);
            result.expect_zk_bytecode(verifiers, &hash, era_expected);
        }
        96 => {
            // Simple ZKsyncOS (non-proxy) bytecodeInfo.
            let observable = FixedBytes::<32>::from_slice(&bytecode_info[64..96]);
            check_zksync_os_observable(result, verifiers, &observable, zksync_os_expected);
        }
        320 => {
            // ZKsyncOS proxy: abi.encode(implInfo_96, proxyInfo_96).
            // ABI layout (manual parse, same as Solidity abi.encode(bytes, bytes)):
            //   [0..32]   = offset_impl  = 64  (0x40)
            //   [32..64]  = offset_proxy = 192 (0xC0)
            //   [64..96]  = len_impl     = 96
            //   [96..192] = impl_96_bytes  → [96..128]=blake [128..160]=len [160..192]=keccak
            //   [192..224]= len_proxy    = 96
            //   [224..320]= proxy_96_bytes
            //
            // Observable (keccak256 of deployed bytecode) lives at raw[160..192].
            let observable = FixedBytes::<32>::from_slice(&bytecode_info[160..192]);
            check_zksync_os_observable(result, verifiers, &observable, zksync_os_expected);
        }
        len => result.report_error(&format!(
            "bytecodeInfo for {era_expected}: unexpected length {len} (expected 32/Era, 96/ZKsyncOS-simple, 320/ZKsyncOS-proxy)"
        )),
    }
}

fn check_zksync_os_observable(
    result: &mut VerificationResult,
    verifiers: &Verifiers,
    observable: &FixedBytes<32>,
    expected_file: &str,
) {
    match verifiers
        .bytecode_verifier
        .evm_deployed_bytecode_hash_to_file(observable)
    {
        Some(file) if file == expected_file => {
            // ok
        }
        Some(file) => result.report_error(&format!(
            "bytecodeInfo for {expected_file}: impl observable hash maps to {file}"
        )),
        None => result.report_error(&format!(
            "bytecodeInfo for {expected_file}: cannot verify observable hash {observable}"
        )),
    }
}

impl FixedForceDeploymentsData {
    pub async fn verify(
        &self,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        match verifiers.network_verifier.try_get_l1_chain_id().await {
            Ok(expected_l1_chain_id) => {
                if U256::from(expected_l1_chain_id) != self.l1ChainId {
                    result.report_error(&format!(
                        "FixedForceDeploymentsData l1ChainId mismatch: expected {}, got {}",
                        expected_l1_chain_id, self.l1ChainId,
                    ));
                } else {
                    result.report_ok(&format!(
                        "FixedForceDeploymentsData l1ChainId matches RPC ({expected_l1_chain_id})"
                    ));
                }
            }
            Err(err) => result.report_error(&format!(
                "Could not verify FixedForceDeploymentsData l1ChainId: {err}"
            )),
        }

        let expected_era_gateway_chain_id = U256::from(verifiers.legacy_gateway_chain_id);
        if self.eraGatewayChainId != expected_era_gateway_chain_id {
            result.report_error(&format!(
                "FixedForceDeploymentsData eraGatewayChainId mismatch: expected legacy gateway chain id {}, got {}",
                verifiers.legacy_gateway_chain_id, self.eraGatewayChainId
            ));
        } else {
            result.report_ok(&format!(
                "FixedForceDeploymentsData eraGatewayChainId matches legacy gateway chain id ({})",
                verifiers.legacy_gateway_chain_id
            ));
        }

        let era_chain_id = verifiers.era_chain_id;
        if U256::from(era_chain_id) != self.eraChainId {
            result.report_error(&format!(
                "FixedForceDeploymentsData eraChainId mismatch: expected {}, got {}",
                era_chain_id, self.eraChainId
            ));
        } else {
            result.report_ok(&format!(
                "FixedForceDeploymentsData eraChainId matches env era_chain_id ({era_chain_id})"
            ));
        }

        result.expect_address(verifiers, &self.l1AssetRouter, "l1_asset_router_proxy");

        // l2TokenProxyBytecodeHash is a ZK hash on Era and an EVM deployed bytecode hash on ZKsyncOS.
        // Try ZK lookup first; fall back to EVM deployed lookup.
        let beacon_proxy_file = "l1-contracts/BeaconProxy";
        let is_zk = verifiers
            .bytecode_verifier
            .zk_bytecode_hash_to_file(&self.l2TokenProxyBytecodeHash)
            .is_some_and(|f| f == beacon_proxy_file);
        let is_evm = verifiers
            .bytecode_verifier
            .evm_deployed_bytecode_hash_to_file(&self.l2TokenProxyBytecodeHash)
            .is_some_and(|f| f == beacon_proxy_file);
        if is_zk || is_evm {
            // ok
        } else if verifiers
            .bytecode_verifier
            .zk_bytecode_hash_to_file(&self.l2TokenProxyBytecodeHash)
            .is_some()
            || verifiers
                .bytecode_verifier
                .evm_deployed_bytecode_hash_to_file(&self.l2TokenProxyBytecodeHash)
                .is_some()
        {
            result.report_error(&format!(
                "l2TokenProxyBytecodeHash maps to wrong contract (expected {})",
                beacon_proxy_file
            ));
        } else {
            result.report_error(&format!(
                "l2TokenProxyBytecodeHash cannot be verified: {} not in AllContractsHashes",
                self.l2TokenProxyBytecodeHash
            ));
        }

        // aliasedL1Governance = applyL1ToL2Alias(Bridgehub.owner()), registered
        // in the address book at `Verifiers::new_v31`.
        let expected_aliased_governance = verifiers
            .address_verifier
            .get_by_name("aliased_protocol_upgrade_handler_proxy")
            .expect(
                "aliased_protocol_upgrade_handler_proxy must be registered by Verifiers::new_v31",
            );
        if self.aliasedL1Governance != expected_aliased_governance {
            result.report_error(&format!(
                "aliasedL1Governance mismatch: expected {expected_aliased_governance}, got {}",
                self.aliasedL1Governance
            ));
        }

        if self.maxNumberOfZKChains != U256::from(MAX_NUMBER_OF_ZK_CHAINS) {
            result.report_error("maxNumberOfZKChains must be 100");
        }

        expect_bytecode_info(
            result,
            verifiers,
            &self.bridgehubBytecodeInfo,
            "l1-contracts/L2Bridgehub",
            "l1-contracts/L2Bridgehub",
        );
        expect_bytecode_info(
            result,
            verifiers,
            &self.l2AssetRouterBytecodeInfo,
            "l1-contracts/L2AssetRouter",
            "l1-contracts/L2AssetRouter",
        );
        expect_bytecode_info(
            result,
            verifiers,
            &self.l2NtvBytecodeInfo,
            "l1-contracts/L2NativeTokenVault",
            "l1-contracts/L2NativeTokenVaultZKOS",
        );
        expect_bytecode_info(
            result,
            verifiers,
            &self.messageRootBytecodeInfo,
            "l1-contracts/L2MessageRoot",
            "l1-contracts/L2MessageRoot",
        );
        expect_bytecode_info(
            result,
            verifiers,
            &self.chainAssetHandlerBytecodeInfo,
            "l1-contracts/L2ChainAssetHandler",
            "l1-contracts/L2ChainAssetHandler",
        );
        expect_bytecode_info(
            result,
            verifiers,
            &self.interopCenterBytecodeInfo,
            "l1-contracts/InteropCenter",
            "l1-contracts/InteropCenter",
        );
        expect_bytecode_info(
            result,
            verifiers,
            &self.interopHandlerBytecodeInfo,
            "l1-contracts/InteropHandler",
            "l1-contracts/InteropHandler",
        );
        expect_bytecode_info(
            result,
            verifiers,
            &self.assetTrackerBytecodeInfo,
            "l1-contracts/L2AssetTracker",
            "l1-contracts/L2AssetTracker",
        );
        expect_bytecode_info(
            result,
            verifiers,
            &self.beaconDeployerInfo,
            "l1-contracts/UpgradeableBeaconDeployer",
            "l1-contracts/UpgradeableBeaconDeployer",
        );
        expect_bytecode_info(
            result,
            verifiers,
            &self.baseTokenHolderBytecodeInfo,
            "l1-contracts/BaseTokenHolder",
            "l1-contracts/BaseTokenHolder",
        );

        result.expect_address(verifiers, &self.l2SharedBridgeLegacyImpl, "zero");
        result.expect_address(verifiers, &self.l2BridgedStandardERC20Impl, "zero");

        let expected_chain_registration_sender = verifiers
            .address_verifier
            .get_by_name("chain_registration_sender_proxy")
            .expect(
                "chain_registration_sender_proxy must be registered by Verifiers::new_v31",
            );
        let expected_chain_registration_sender_alias = apply_l2_to_l1_alias(expected_chain_registration_sender);
        if self.aliasedChainRegistrationSender == expected_chain_registration_sender_alias {
            result.report_ok(&format!(
                "aliasedChainRegistrationSender matches applyL1ToL2Alias(Bridgehub.chainRegistrationSender()) = {expected_chain_registration_sender_alias}"
            ));
        } else {
            result.report_error(&format!(
                "aliasedChainRegistrationSender mismatch: expected {} (alias of {}), got {}",
                expected_chain_registration_sender_alias, expected_chain_registration_sender, self.aliasedChainRegistrationSender
            ));
        }

        if self.dangerousTestOnlyForcedBeacon != Address::ZERO {
            result.report_error("dangerousTestOnlyForcedBeacon must be 0");
        }

        let expected = verifiers.zk_token_asset_id;
        if self.zkTokenAssetId == expected {
            result.report_ok(&format!("zkTokenAssetId matches env value ({expected})"));
        } else {
            result.report_error(&format!(
                "zkTokenAssetId mismatch: expected {expected}, got {}",
                self.zkTokenAssetId
            ));
        }

        Ok(())
    }
}
